require "test_helper"

class MonobankItem::SyncerTest < ActiveSupport::TestCase
  include MonobankTestHelper
  include ActiveJob::TestHelper

  CLIENT_INFO = "https://api.monobank.ua/personal/client-info".freeze
  STATEMENT = %r{\Ahttps://api\.monobank\.ua/personal/statement/}

  setup do
    travel_to Time.zone.parse("2026-11-16 12:00:00 UTC")
    setup_monobank_family
    Provider::Monobank.any_instance.expects(:sleep).never
    # Booking rows is MonobankAccount::Processor's (tested there)
    MonobankAccount::Processor.any_instance.stubs(:process).returns({})
    clear_enqueued_jobs
  end

  teardown { travel_back }

  def client_info_body(balance: 100_00)
    { clientId: "c1", accounts: [ { id: "card-uah", currencyCode: 980, type: "black", balance: balance, creditLimit: 0 } ], jars: [] }.to_json
  end

  def run_sync(parent: nil)
    sync = @item.syncs.create!(parent: parent)
    sync.start!
    MonobankItem::Syncer.new(@item).perform_sync(sync)
    sync.reload
  end

  test "a sync makes one client-info request, no statement request, and starts the fetch chain" do
    info = stub_request(:get, CLIENT_INFO).to_return(status: 200, body: client_info_body)
    product = create_monobank_product(account_id: "card-uah", balance: 100_00)
    link_product(product, create_sure_account(name: "Card"))

    sync = run_sync

    assert_requested info, times: 1
    assert_not_requested :get, STATEMENT
    assert @item.reload.fetch_chain_token.present?
    assert_enqueued_with(job: MonobankStatementFetchJob, args: [ @item, @item.fetch_chain_token ])
    assert_equal 12, sync.sync_stats["statement_windows_remaining"]
    assert_equal true, sync.sync_stats["chain_active"]
    assert_equal "imported", sync.sync_stats["client_info"]
  end

  test "a live chain is not started twice" do
    stub_request(:get, CLIENT_INFO).to_return(status: 200, body: client_info_body)
    product = create_monobank_product(account_id: "card-uah", balance: 100_00)
    link_product(product, create_sure_account(name: "Card"))
    run_sync
    token = @item.reload.fetch_chain_token
    clear_enqueued_jobs

    ProviderRateLimitSlot.delete_all
    run_sync

    assert_equal token, @item.reload.fetch_chain_token
    assert_no_enqueued_jobs(only: MonobankStatementFetchJob)
  end

  test "a lost chain (no heartbeat for 5 minutes) is replaced" do
    product = create_monobank_product(account_id: "card-uah", balance: 100_00)
    link_product(product, create_sure_account(name: "Card"))
    @item.update!(fetch_chain_token: SecureRandom.uuid, fetch_chain_heartbeat_at: 6.minutes.ago)
    stub_request(:get, CLIENT_INFO).to_return(status: 200, body: client_info_body)

    old = @item.fetch_chain_token
    run_sync

    assert_not_equal old, @item.reload.fetch_chain_token
  end

  test "a busy client-info slot is not a failure" do
    create_monobank_product(account_id: "card-uah", balance: 100_00)
    @item.monobank_provider.reserve_request_slot!(:client_info)

    sync = run_sync

    assert_not_requested :get, CLIENT_INFO
    assert_equal "rate_limited", sync.sync_stats["client_info"]
    assert_equal 0, sync.sync_stats["total_errors"]
  end

  test "new products ask for setup" do
    stub_request(:get, CLIENT_INFO).to_return(status: 200, body: client_info_body)

    run_sync

    assert @item.reload.pending_account_setup?
    assert_equal 1, @item.monobank_accounts.count
  end

  test "a refused token fails the sync and marks the connection" do
    stub_request(:get, CLIENT_INFO).to_return(status: 401, body: "{}")

    assert_raises(MonobankItem::Syncer::SyncError) { run_sync }
    assert @item.reload.requires_update?
  end

  test "a connection that needs a new token fails without a request" do
    @item.update!(status: :requires_update)

    assert_raises(MonobankItem::Syncer::SyncError) { run_sync }
    assert_not_requested :get, CLIENT_INFO
  end

  test "a network error with stored products keeps going" do
    create_monobank_product(account_id: "card-uah")
    stub_request(:get, CLIENT_INFO).to_timeout

    sync = run_sync
    assert_equal "failed", sync.sync_stats["client_info"]
  end

  test "processes linked products and schedules their balance syncs as children" do
    stub_request(:get, CLIENT_INFO).to_return(status: 200, body: client_info_body)
    product = create_monobank_product(account_id: "card-uah", balance: 100_00)
    account = create_sure_account(name: "Card")
    link_product(product, account)
    MonobankAccount::Processor.any_instance.expects(:process).returns({ claimed: 2, skipped_before_cutover: 1, pruned: 1, detached: 0, imported: 5 })

    sync = run_sync

    assert_equal 2, sync.sync_stats["monobank_claimed"]
    assert_equal 1, sync.sync_stats["monobank_skipped_before_cutover"]
    assert_equal sync, account.syncs.ordered.first.parent
  end

  test "post-sync runs the family steps only for a sync of the connection alone" do
    @item.syncs.create!
    Family::ProviderPostSync.any_instance.expects(:run).once
    MonobankItem::Syncer.new(@item).perform_post_sync

    travel 1.second
    family_sync = @family.syncs.create!
    @item.syncs.create!(parent: family_sync)
    Family::ProviderPostSync.any_instance.expects(:run).never
    MonobankItem::Syncer.new(@item).perform_post_sync
  end

  test "a whole Sync record finishes in one job run" do
    stub_request(:get, CLIENT_INFO).to_return(status: 200, body: client_info_body)
    create_monobank_product(account_id: "card-uah", balance: 100_00)

    sync = @item.sync_later
    perform_enqueued_jobs(only: SyncJob)

    assert sync.reload.completed?
  end
  test "a busy client-info slot with no product yet schedules a sync for when it frees" do
    @item.update_columns(created_at: 1.minute.ago)
    @item.monobank_provider.reserve_request_slot!(:client_info)

    run_sync

    job = enqueued_jobs.find { |j| j["job_class"] == "DelayedSyncJob" }
    assert job, "a follow-up sync"
    assert_in_delta (Time.current + 61.seconds).to_f, job["scheduled_at"].to_time.to_f, 2
    assert @item.reload.waiting_for_client_info?
    assert_equal "Waiting for monobank to list your accounts (it answers one request a minute)", @item.sync_status_summary

    clear_enqueued_jobs
    @item.update_columns(created_at: 2.hours.ago)
    run_sync
    assert_no_enqueued_jobs only: DelayedSyncJob
  end

  test "with monobank switched off a queued sync makes no request" do
    enable_bank_connections(:plaid)
    create_monobank_product(account_id: "card-uah")

    sync = run_sync

    assert_not_requested :get, CLIENT_INFO
    assert_nil @item.reload.fetch_chain_token
    assert_nil sync.sync_stats.to_h["client_info"]
  end

  test "post-sync rules run only when the sync booked new entries" do
    @item.syncs.create!(sync_stats: { "monobank_created" => 0 })
    Family::ProviderPostSync.any_instance.expects(:run).with(new_entries: false).once
    MonobankItem::Syncer.new(@item).perform_post_sync

    travel 1.second
    @item.syncs.create!(sync_stats: { "monobank_created" => 2 })
    Family::ProviderPostSync.any_instance.expects(:run).with(new_entries: true).once
    MonobankItem::Syncer.new(@item).perform_post_sync
  end

  test "products whose statement keeps failing are in the sync stats" do
    stub_request(:get, CLIENT_INFO).to_return(status: 200, body: client_info_body)
    product = create_monobank_product(account_id: "card-uah", balance: 100_00)
    link_product(product, create_sure_account(name: "Card"))
    product.update!(fetch_failures: 5, next_fetch_after: 30.minutes.from_now)

    sync = run_sync

    assert_equal [ product.name ], sync.sync_stats["statement_failing_products"]
    assert_operator sync.sync_stats["statement_windows_remaining"], :>, 0
  end
end
