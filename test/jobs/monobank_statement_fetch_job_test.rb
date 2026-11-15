require "test_helper"

class MonobankStatementFetchJobTest < ActiveJob::TestCase
  include MonobankTestHelper

  STATEMENT = %r{\Ahttps://api\.monobank\.ua/personal/statement/}

  setup do
    travel_to Time.zone.parse("2026-11-16 12:00:00 UTC")
    setup_monobank_family
    @product = create_monobank_product(account_id: "card-uah", balance: 100_00)
    link_product(@product, create_sure_account(name: "Card"))
    @token = SecureRandom.uuid
    @item.update!(fetch_chain_token: @token, fetch_chain_heartbeat_at: Time.current)
    Provider::Monobank.any_instance.expects(:sleep).never
    clear_enqueued_jobs
  end

  teardown { travel_back }

  def next_fetch_jobs
    enqueued_jobs.select { |job| job["job_class"] == "MonobankStatementFetchJob" }
  end

  test "makes one request, stores the rows and schedules itself for the next slot" do
    stub = stub_request(:get, STATEMENT).to_return(status: 200, body: [ { id: "t1", time: 1.day.ago.to_i, amount: -100 } ].to_json)

    MonobankStatementFetchJob.perform_now(@item, @token)

    assert_requested stub, times: 1
    assert_equal [ "t1" ], @product.reload.raw_transactions_payload.map { |row| row["id"] }
    job = next_fetch_jobs.sole
    assert_in_delta (Time.current + 61.seconds).to_f, job["scheduled_at"].to_time.to_f, 2
    assert_equal 1, job["arguments"].last
    assert_in_delta (Time.current + 61.seconds).to_f, @item.reload.fetch_chain_heartbeat_at.to_f, 2
    assert_equal 0, Entry.where(source: "monobank").count, "the job stores rows only"
  end

  test "a job of an older chain does nothing" do
    MonobankStatementFetchJob.perform_now(@item, SecureRandom.uuid)

    assert_not_requested :get, STATEMENT
    assert_empty enqueued_jobs
  end

  test "a busy slot reschedules without a request" do
    Provider::Monobank.new(@item.access_token).reserve_request_slot!(:statement)

    MonobankStatementFetchJob.perform_now(@item, @token, 3)

    assert_not_requested :get, STATEMENT
    job = next_fetch_jobs.sole
    assert_in_delta (Time.current + 61.seconds).to_f, job["scheduled_at"].to_time.to_f, 2
    assert_equal 3, job["arguments"].last
  end

  test "429 defers the slot and reschedules after it" do
    stub_request(:get, STATEMENT).to_return(status: 429, body: { errorDescription: "Too many requests" }.to_json)

    MonobankStatementFetchJob.perform_now(@item, @token)

    job = next_fetch_jobs.sole
    assert_operator job["scheduled_at"].to_time, :>=, Time.current + 60.seconds
    assert_nil @product.reload.statement_synced_through
  end

  test "a refused token stops the chain and marks the connection" do
    stub_request(:get, STATEMENT).to_return(status: 401, body: "{}")

    MonobankStatementFetchJob.perform_now(@item, @token)

    @item.reload
    assert @item.requires_update?
    assert_nil @item.fetch_chain_token
    assert_empty next_fetch_jobs
  end

  test "400 on a backfill window ends the history there" do
    @product.update!(statement_synced_through: Time.current, forward_fetched_at: Time.current, balance_at_forward_fetch: 100_00,
                     history_synced_from: 40.days.ago)
    stub_request(:get, STATEMENT).to_return(status: 400, body: { errorDescription: "Period must be no more than 31 days" }.to_json)

    MonobankStatementFetchJob.perform_now(@item, @token)

    assert @product.reload.history_complete?
    assert_equal 1, next_fetch_jobs.size
  end

  test "a server error backs this product off and the chain goes on" do
    stub_request(:get, STATEMENT).to_return(status: 500, body: "{}")

    MonobankStatementFetchJob.perform_now(@item, @token)

    @product.reload
    assert_equal 1, @product.fetch_failures
    assert_in_delta (Time.current + 2.minutes).to_f, @product.next_fetch_after.to_f, 2
    assert_equal 1, next_fetch_jobs.size
  end

  test "nothing left to fetch: ends the chain and asks for a sync" do
    @product.update!(statement_synced_through: Time.current, forward_fetched_at: Time.current, balance_at_forward_fetch: 100_00,
                     history_synced_from: 400.days.ago, history_complete: true)

    assert_difference -> { @item.syncs.count }, 1 do
      MonobankStatementFetchJob.perform_now(@item, @token)
    end

    assert_nil @item.reload.fetch_chain_token
    assert_empty next_fetch_jobs
    assert_not_requested :get, STATEMENT
  end

  test "every 5 completed windows asks for a sync that books the rows" do
    stub_request(:get, STATEMENT).to_return(status: 200, body: "[]")

    assert_no_difference -> { @item.syncs.count } do
      MonobankStatementFetchJob.perform_now(@item, @token, 3)
    end
    assert_difference -> { @item.syncs.count }, 1 do
      ProviderRateLimitSlot.delete_all
      MonobankStatementFetchJob.perform_now(@item, @token, 4)
    end
  end

  test "a whole backfill: one request per run until done" do
    stub = stub_request(:get, STATEMENT).to_return(status: 200, body: "[]")
    runs = 0

    loop do
      job = next_fetch_jobs.last
      args = job ? ActiveJob::Arguments.deserialize(job["arguments"]) : [ @item, @token ]
      clear_enqueued_jobs
      travel_to(job["scheduled_at"].to_time) if job
      MonobankStatementFetchJob.perform_now(*args)
      runs += 1
      break if next_fetch_jobs.empty?
      flunk "chain did not end" if runs > 30
    end

    assert_requested stub, times: 12
    assert_equal 13, runs
    assert @product.reload.history_complete?
    assert_nil @item.reload.fetch_chain_token
  end
  test "a product backed off for a while does not park the chain: Sync now for another one is fetched within two slots" do
    bad = create_monobank_product(account_id: "bad")
    link_product(bad, create_sure_account(name: "Bad"))
    bad.update!(fetch_failures: 4, next_fetch_after: 16.minutes.from_now)
    @product.update!(statement_synced_through: Time.current, forward_fetched_at: Time.current, balance_at_forward_fetch: 100_00,
                     history_synced_from: 400.days.ago, history_complete: true)

    MonobankStatementFetchJob.perform_now(@item, @token)

    job = next_fetch_jobs.sole
    assert_operator job["scheduled_at"].to_time, :<=, Time.current + 2.minutes + 2.seconds
    assert_equal true, ActiveJob::Arguments.deserialize(job["arguments"]).last, "parked"

    travel 1.minute
    @item.force_forward!
    travel_to job["scheduled_at"].to_time
    stub = stub_request(:get, %r{/personal/statement/card-uah/}).to_return(status: 200, body: "[]")
    clear_enqueued_jobs
    assert_no_difference -> { @item.syncs.count }, "a parked chain asks for one sync only" do
      MonobankStatementFetchJob.perform_now(*ActiveJob::Arguments.deserialize(job["arguments"]))
    end

    assert_requested stub, times: 1
  end

  test "a job that finds the connection refused ends its chain, so a new token starts one at once" do
    @item.update!(status: :requires_update)

    MonobankStatementFetchJob.perform_now(@item, @token)

    assert_nil @item.reload.fetch_chain_token
    assert_not @item.fetch_chain_active?
  end

  test "with monobank switched off the chain makes no request and ends" do
    enable_bank_connections(:plaid)

    MonobankStatementFetchJob.perform_now(@item, @token)

    assert_not_requested :get, STATEMENT
    assert_empty next_fetch_jobs
    assert_nil @item.reload.fetch_chain_token
    assert_nil @item.ensure_fetch_chain!
  end
end
