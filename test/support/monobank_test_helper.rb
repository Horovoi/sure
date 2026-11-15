# Builders for the monobank model, job and controller tests
module MonobankTestHelper
  CURRENCY_CODES = { "UAH" => 980, "USD" => 840, "EUR" => 978 }.freeze

  # monobank switched on (BankConnections), as in production
  def setup_monobank_family
    enable_bank_connections(:monobank)
    @family = families(:dylan_family)
    @family.update!(timezone: "Europe/Kyiv")
    @item = monobank_items(:one)
    @item.monobank_accounts.destroy_all
  end

  # A product as client-info reports it (minor units)
  def create_monobank_product(account_id:, currency: "UAH", kind: "card", type: "black", balance: 0, credit_limit: 0,
                              iban: nil, title: nil, goal: nil, item: @item)
    product = item.monobank_accounts.new
    product.upsert_monobank_snapshot!(
      id: account_id, kind: kind, type: (kind == "jar" ? nil : type), currencyCode: CURRENCY_CODES.fetch(currency),
      balance: balance, creditLimit: credit_limit, maskedPan: [ "537541******1234" ], iban: iban, title: title, goal: goal
    )
    product
  end

  def create_sure_account(name:, accountable_type: "Depository", currency: "UAH", balance: 0, family: @family)
    Account.create_and_sync(
      { family: family, name: name, balance: balance, currency: currency, accountable_type: accountable_type, accountable_attributes: {} },
      skip_initial_sync: true
    )
  end

  def link_product(product, account, cutover_date: nil)
    Account::ProviderLink.link!(account: account, provider_account: product, cutover_date: cutover_date)
    product.reload
  end

  def monobank_row(id:, time:, amount:, hold: false, description: "Сільпо", mcc: 5411, balance: nil, **extra)
    {
      "id" => id, "time" => time.to_i, "description" => description, "mcc" => mcc, "originalMcc" => mcc,
      "hold" => hold, "amount" => amount, "operationAmount" => amount, "currencyCode" => 980,
      "commissionRate" => 0, "cashbackAmount" => 0, "balance" => balance
    }.merge(extra.transform_keys(&:to_s)).compact
  end

  def add_manual_transaction(account, date:, amount:, name: "Manual entry", **attributes)
    account.entries.create!(
      date: date, amount: amount, currency: account.currency, name: name,
      entryable: Transaction.new, **attributes
    )
  end
end
