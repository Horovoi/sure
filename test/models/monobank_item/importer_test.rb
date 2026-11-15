require "test_helper"

class MonobankItem::ImporterTest < ActiveSupport::TestCase
  include MonobankTestHelper

  CLIENT_INFO = {
    clientId: "client-1",
    name: "Owner Name",
    accounts: [
      { id: "uah-card", currencyCode: 980, type: "black", balance: 4_200_000, creditLimit: 5_000_000, maskedPan: [ "537541******1234" ], iban: "UA111" },
      { id: "usd-card", currencyCode: 840, type: "black", balance: 12_345, creditLimit: 0, maskedPan: [ "537541******1234" ], iban: "UA222" },
      { id: "eur-card", currencyCode: 978, type: "white", balance: 500, creditLimit: 0, maskedPan: [] },
      { id: "fop-uah", currencyCode: 980, type: "fop", balance: 1_000_000, creditLimit: 0, iban: "UA333" }
    ],
    jars: [ { id: "jar-1", title: "Відпустка", currencyCode: 980, balance: 150_000, goal: 2_000_000 } ]
  }.freeze

  setup do
    setup_monobank_family
    @provider = Provider::Monobank.new("token")
    @importer = MonobankItem::Importer.new(@item, provider: @provider)
    Provider::Monobank.any_instance.expects(:sleep).never
  end

  test "imports every product: cards, currency accounts, FOP and jars" do
    stub_request(:get, "https://api.monobank.ua/personal/client-info").to_return(status: 200, body: CLIENT_INFO.to_json)

    result = @importer.import_client_info!

    assert_equal :imported, result[:status]
    assert_equal 5, result[:discovered]
    products = @item.monobank_accounts.reload.index_by(&:account_id)

    uah = products["uah-card"]
    assert_equal [ "UAH", "card", "black", "1234" ], [ uah.currency, uah.account_kind, uah.account_type, uah.last4 ]
    assert_equal "Black card ·1234", uah.name
    assert_equal 4_200_000, uah.raw_balance_minor
    assert_equal 50_000, uah.credit_limit
    assert_equal "CreditCard", uah.suggested_account_type
    assert_equal 8_000, uah.balance_for("CreditCard")
    assert_equal(-8_000, uah.balance_for("Depository"))
    assert_equal "UA111", uah.iban

    usd = products["usd-card"]
    assert_equal [ "USD", "Depository", "checking" ], [ usd.currency, usd.suggested_account_type, usd.suggested_subtype ]
    assert_equal "Black card ·1234 · USD", usd.name
    assert_equal BigDecimal("123.45"), usd.balance_for("Depository")

    assert_equal "EUR", products["eur-card"].currency
    assert_equal "FOP · UAH", products["fop-uah"].name
    assert products["fop-uah"].fop?

    jar = products["jar-1"]
    assert jar.jar?
    assert_equal [ "Відпустка", "savings", BigDecimal("20000") ], [ jar.name, jar.suggested_subtype, jar.goal ]
    assert_equal 1_500, jar.balance_for("Depository")

    @item.reload
    assert_equal "client-1", @item.client_id
    assert_nil @item.raw_payload["name"], "the client's name is not stored"
    assert @item.pending_account_setup?
  end

  test "a renamed product keeps its name; balances refresh" do
    stub_request(:get, "https://api.monobank.ua/personal/client-info").to_return(status: 200, body: CLIENT_INFO.to_json)
    @importer.import_client_info!
    product = @item.monobank_accounts.find_by!(account_id: "uah-card")
    product.update!(name: "Mono Visa")

    ProviderRateLimitSlot.delete_all
    changed = CLIENT_INFO.deep_dup
    changed[:accounts][0][:balance] = 4_100_000
    stub_request(:get, "https://api.monobank.ua/personal/client-info").to_return(status: 200, body: changed.to_json)

    assert_equal 0, @importer.import_client_info![:discovered]
    assert_equal [ "Mono Visa", 4_100_000 ], [ product.reload.name, product.raw_balance_minor ]
  end

  test "a busy client-info slot keeps the stored snapshot" do
    @provider.reserve_request_slot!(:client_info)

    assert_equal :rate_limited, @importer.import_client_info![:status]
    assert_not_requested :get, /client-info/
  end

  test "a refused token marks the connection requires_update" do
    stub_request(:get, "https://api.monobank.ua/personal/client-info").to_return(status: 403, body: "{}")

    assert_raises(Provider::Monobank::Error) { @importer.import_client_info! }
    assert @item.reload.requires_update?
  end

  test "store_window! merges rows by id and moves the cursors" do
    product = create_monobank_product(account_id: "uah-card", balance: 100_00)
    link_product(product, create_sure_account(name: "Card"))
    window = MonobankItem::FetchPlan::Window.new(product, 5.days.ago, Time.current, :first)

    @importer.store_window!(window, [ monobank_row(id: "a", time: 1.day.ago, amount: -100), monobank_row(id: "b", time: 2.days.ago, amount: -200) ])
    @importer.store_window!(window, [ monobank_row(id: "a", time: 1.day.ago, amount: -150) ])

    product.reload
    assert_equal({ "a" => -150, "b" => -200 }, product.raw_transactions_payload.to_h { |row| [ row["id"], row["amount"] ] })
    assert_equal 100_00, product.balance_at_forward_fetch
    assert product.forward_fetched_at.present?
  end

  test "a forward window drops holds it no longer reports, keeps older ones and settled rows" do
    product = create_monobank_product(account_id: "uah-card")
    link_product(product, create_sure_account(name: "Card"))
    product.update!(raw_transactions_payload: [
      monobank_row(id: "gone-hold", time: 1.day.ago, amount: -100, hold: true),
      monobank_row(id: "old-hold", time: 10.days.ago, amount: -300, hold: true),
      monobank_row(id: "ancient-hold", time: 40.days.ago, amount: -300, hold: true),
      monobank_row(id: "settled", time: 1.day.ago, amount: -50)
    ])

    window = MonobankItem::FetchPlan::Window.new(product, 3.days.ago, Time.current, :forward)
    @importer.store_window!(window, [ monobank_row(id: "new", time: 1.hour.ago, amount: -10, hold: true) ])

    ids = product.reload.raw_transactions_payload.map { |row| row["id"] }
    assert_equal %w[new old-hold settled].sort, ids.sort
  end

  test "holds are not stored when the connection turns them off" do
    @item.update!(include_pending: false)
    product = create_monobank_product(account_id: "uah-card")
    window = MonobankItem::FetchPlan::Window.new(product, 3.days.ago, Time.current, :forward)

    @importer.store_window!(window, [ monobank_row(id: "h", time: 1.hour.ago, amount: -10, hold: true), monobank_row(id: "s", time: 1.hour.ago, amount: -10) ])

    assert_equal [ "s" ], product.reload.raw_transactions_payload.map { |row| row["id"] }
  end

  test "failures back off per product, success resets" do
    product = create_monobank_product(account_id: "uah-card", balance: 1)
    error = Provider::Monobank::Error.new("boom", failure_code: :server_error)

    @importer.record_fetch_failure!(product, error)
    @importer.record_fetch_failure!(product, error)
    product.reload
    assert_equal 2, product.fetch_failures
    assert_in_delta (Time.current + 4.minutes).to_f, product.next_fetch_after.to_f, 2

    @importer.store_window!(MonobankItem::FetchPlan::Window.new(product, 1.day.ago, Time.current, :first), [])
    assert_equal [ 0, nil ], [ product.reload.fetch_failures, product.next_fetch_after ]
  end
end
