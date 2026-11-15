require "test_helper"

class MonobankItemTest < ActiveSupport::TestCase
  include MonobankTestHelper
  include ActiveJob::TestHelper

  setup do
    travel_to Time.zone.parse("2026-11-16 12:00:00 UTC")
    setup_monobank_family
  end

  teardown { travel_back }

  test "the token is encrypted and required" do
    assert_not_equal "test_monobank_token", @item.read_attribute_before_type_cast(:access_token)
    assert_not MonobankItem.new(family: @family, name: "x").valid?
  end

  test "Family#create_monobank_item! creates the connection and queues its sync" do
    item = nil
    assert_enqueued_with(job: SyncJob) do
      item = @family.create_monobank_item!(access_token: "tok", sync_start_date: Date.new(2026, 1, 1))
    end

    assert_equal [ "monobank", Date.new(2026, 1, 1), "monobank.ua" ], [ item.name, item.sync_start_date, item.institution_domain ]
    assert item.syncs.any?
  end

  test "link_existing_account! links a hand-kept card with a cutover after its last entry" do
    product = create_monobank_product(account_id: "card-uah", balance: 4_200_000, credit_limit: 5_000_000)
    visa = create_sure_account(name: "Mono Visa", accountable_type: "CreditCard", balance: 8_000)
    add_manual_transaction(visa, date: Date.new(2026, 11, 12), amount: 100)

    link = @item.link_existing_account!(monobank_account: product, account: visa)

    assert_equal [ visa, product, Date.new(2026, 11, 13) ], [ link.account, link.provider, link.cutover_date ]
    assert_equal Date.new(2026, 11, 13), visa.reload.provider_cutover_date
    assert @item.syncs.any?
  end

  test "link_existing_account! takes an explicit cutover and refuses another currency" do
    product = create_monobank_product(account_id: "card-uah")
    usd = create_sure_account(name: "Dollars", currency: "USD")
    assert_raises(ArgumentError) { @item.link_existing_account!(monobank_account: product, account: usd) }

    account = create_sure_account(name: "Card")
    link = @item.link_existing_account!(monobank_account: product, account: account, cutover_date: "2026-11-01")
    assert_equal Date.new(2026, 11, 1), link.cutover_date

    other = create_sure_account(name: "Other")
    assert_raises(Account::ProviderLink::AlreadyLinked) { @item.link_existing_account!(monobank_account: product, account: other) }
  end

  test "create_linked_account! makes a new account of the suggested type, opened before the target start" do
    card = create_monobank_product(account_id: "card-uah", balance: 4_200_000, credit_limit: 5_000_000)
    jar = create_monobank_product(account_id: "jar-1", kind: "jar", title: "Відпустка", balance: 150_000)
    fop = create_monobank_product(account_id: "fop-1", type: "fop", balance: 10_000)

    card_account = @item.create_linked_account!(monobank_account: card)
    jar_account = @item.create_linked_account!(monobank_account: jar)
    fop_account = @item.create_linked_account!(monobank_account: fop, name: "Business")

    assert_equal [ "CreditCard", "credit_card", "UAH" ], [ card_account.accountable_type, card_account.subtype, card_account.currency ]
    assert_equal [ "Depository", "savings", "Відпустка" ], [ jar_account.accountable_type, jar_account.subtype, jar_account.name ]
    assert_equal [ "Depository", "checking", "Business" ], [ fop_account.accountable_type, fop_account.subtype, fop_account.name ]
    assert_nil card_account.provider_cutover_date
    assert_equal (MonobankItem::FetchPlan.target_start_for(card).to_date - 1.day), card_account.opening_anchor_date
    assert_equal card, card_account.account_providers.sole.provider
    assert_not @item.reload.pending_account_setup?
  end

  test "create_linked_account! refuses an unsupported type" do
    product = create_monobank_product(account_id: "card-uah")
    assert_raises(ArgumentError) { @item.create_linked_account!(monobank_account: product, accountable_type: "Loan") }
  end

  test "backfill_progress counts the requests left" do
    product = create_monobank_product(account_id: "card-uah")
    @item.create_linked_account!(monobank_account: product)

    progress = @item.reload.backfill_progress

    assert_equal 12, progress[:windows_remaining]
    assert_equal 12 * 61, progress[:eta_seconds]
    assert_equal false, progress[:chain_active]
  end

  test "fetch_chain_active? needs a token and a recent heartbeat" do
    assert_not @item.fetch_chain_active?
    @item.update!(fetch_chain_token: SecureRandom.uuid, fetch_chain_heartbeat_at: 1.minute.from_now)
    assert @item.fetch_chain_active?
    assert_not @item.fetch_chain_active?(now: 7.minutes.from_now)
  end

  test "unlink_all! turns linked accounts into manual ones and keeps them" do
    product = create_monobank_product(account_id: "card-uah")
    account = @item.create_linked_account!(monobank_account: product)

    results = @item.unlink_all!

    assert_equal account.id, results.sole[:account_id]
    assert_not account.reload.linked?
  end

  test "destroying a connection keeps the Sure accounts" do
    product = create_monobank_product(account_id: "card-uah")
    account = @item.create_linked_account!(monobank_account: product)

    @item.destroy!

    assert Account.exists?(account.id)
    assert_not account.reload.linked?
  end

  test "destroy_later flags the connection and queues the job" do
    assert_enqueued_with(job: DestroyJob) { @item.destroy_later }
    assert @item.reload.scheduled_for_deletion?
  end

  test "is a registered, hourly bank connection whose balance includes holds" do
    provider = BankConnections.provider(:monobank)

    assert_equal [ :monobank_items, "MonobankItem", "MonobankAccount" ], [ provider.association, provider.item_class_name, provider.account_class_name ]
    assert provider.hourly?
    assert provider.balance_includes_pending?
    assert provider.generic_listing?
    assert_equal "settings/providers/monobank_panel", provider.settings_partial
  end
end
