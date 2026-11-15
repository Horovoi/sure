require "test_helper"

class BalanceSheetTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @family = families(:empty)
  end

  test "calculates total assets" do
    assert_equal 0, BalanceSheet.new(@family).assets.total

    create_account(balance: 1000, accountable: Depository.new)
    create_account(balance: 5000, accountable: OtherAsset.new)
    create_account(balance: 10000, accountable: CreditCard.new) # ignored

    assert_equal 1000 + 5000, BalanceSheet.new(@family).assets.total
  end

  test "calculates total liabilities" do
    assert_equal 0, BalanceSheet.new(@family).liabilities.total

    create_account(balance: 1000, accountable: CreditCard.new)
    create_account(balance: 5000, accountable: OtherLiability.new)
    create_account(balance: 10000, accountable: Depository.new) # ignored

    assert_equal 1000 + 5000, BalanceSheet.new(@family).liabilities.total
  end

  test "calculates net worth" do
    assert_equal 0, BalanceSheet.new(@family).net_worth

    create_account(balance: 1000, accountable: CreditCard.new)
    create_account(balance: 50000, accountable: Depository.new)

    assert_equal 50000 - 1000, BalanceSheet.new(@family).net_worth
  end

  test "disabled accounts do not affect totals" do
    create_account(balance: 1000, accountable: CreditCard.new)
    create_account(balance: 10000, accountable: Depository.new)

    other_liability = create_account(balance: 5000, accountable: OtherLiability.new)
    other_liability.disable!

    assert_equal 10000 - 1000, BalanceSheet.new(@family).net_worth
    assert_equal 10000, BalanceSheet.new(@family).assets.total
    assert_equal 1000, BalanceSheet.new(@family).liabilities.total
  end

  test "draft accounts are listed but not counted in totals" do
    create_account(balance: 10000, accountable: Depository.new)
    draft = create_account(balance: 250000, accountable: Property.new, status: "draft")

    balance_sheet = BalanceSheet.new(@family)

    assert_equal 10000, balance_sheet.assets.total
    assert_equal 10000, balance_sheet.net_worth
    property_group = balance_sheet.assets.account_groups.find { |group| group.key == "property" }
    assert_equal [ draft.id ], property_group.accounts.map(&:id)
    assert_equal 0, property_group.total
  end

  test "calculates asset group totals" do
    create_account(balance: 1000, accountable: Depository.new)
    create_account(balance: 2000, accountable: Depository.new)
    create_account(balance: 3000, accountable: Investment.new)
    create_account(balance: 5000, accountable: OtherAsset.new)
    create_account(balance: 10000, accountable: CreditCard.new) # ignored

    asset_groups = BalanceSheet.new(@family).assets.account_groups

    assert_equal 3, asset_groups.size
    assert_equal 1000 + 2000, asset_groups.find { |ag| ag.name == I18n.t("accounts.types.depository") }.total
    assert_equal 3000, asset_groups.find { |ag| ag.name == I18n.t("accounts.types.investment") }.total
    assert_equal 5000, asset_groups.find { |ag| ag.name == I18n.t("accounts.types.other_asset") }.total
  end

  test "calculates liability group totals" do
    create_account(balance: 1000, accountable: CreditCard.new)
    create_account(balance: 2000, accountable: CreditCard.new)
    create_account(balance: 3000, accountable: OtherLiability.new)
    create_account(balance: 5000, accountable: OtherLiability.new)
    create_account(balance: 10000, accountable: Depository.new) # ignored

    liability_groups = BalanceSheet.new(@family).liabilities.account_groups

    assert_equal 2, liability_groups.size
    assert_equal 1000 + 2000, liability_groups.find { |ag| ag.name == I18n.t("accounts.types.credit_card") }.total
    assert_equal 3000 + 5000, liability_groups.find { |ag| ag.name == I18n.t("accounts.types.other_liability") }.total
  end

  test "an account in a currency with no exchange rate is left out of net worth, not counted at 1" do
    @family.update_columns(currency: "UAH")
    create_account(balance: 1000, currency: "UAH", accountable: Depository.new)
    create_account(balance: 50, currency: "USD", accountable: Depository.new)

    assert_equal 1000, BalanceSheet.new(@family).net_worth
  end

  test "an account converts at the nearest stored rate when today's is missing" do
    @family.update_columns(currency: "UAH")
    create_account(balance: 1000, currency: "UAH", accountable: Depository.new)
    create_account(balance: 50, currency: "USD", accountable: Depository.new)
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: 12.days.ago.to_date, rate: 40)

    assert_equal 1000 + 50 * 40, BalanceSheet.new(@family).net_worth
  end

  # -- Past net worth and disabled accounts -----------------------------------

  test "past net worth counts a disabled account before it was disabled, not after" do
    zone = @family.resolved_time_zone
    period = Period.custom(start_date: Date.new(2026, 3, 8), end_date: Date.new(2026, 3, 10))

    active = create_account(balance: 10_000, accountable: Depository.new)
    disabled = create_account(balance: 5_000, accountable: Depository.new)
    draft = create_account(balance: 1_000, accountable: Property.new, status: "draft")
    deleting = create_account(balance: 7_000, accountable: Depository.new)

    [ active, disabled, draft, deleting ].each do |account|
      create_balance(account: account, date: Date.new(2026, 3, 7), balance: account.balance)
    end

    travel_to(zone.local(2026, 3, 9, 12)) { disabled.disable! }
    deleting.mark_for_deletion!

    travel_to zone.local(2026, 3, 10, 12) do
      balance_sheet = BalanceSheet.new(@family)
      values = balance_sheet.net_worth_series(period: period).values.to_h { |v| [ v.date, v.value.amount ] }

      # Counted on the days before it was disabled; its last balance is not
      # carried into the days after. The draft and the deletion never count.
      assert_equal 15_000, values.fetch(Date.new(2026, 3, 8))
      assert_equal 10_000, values.fetch(Date.new(2026, 3, 9))
      assert_equal 10_000, values.fetch(Date.new(2026, 3, 10))
      assert_equal 10_000, balance_sheet.net_worth
    end
  end

  test "an enabled account counts in past net worth on every day again" do
    zone = @family.resolved_time_zone
    period = Period.custom(start_date: Date.new(2026, 3, 8), end_date: Date.new(2026, 3, 10))

    account = create_account(balance: 5_000, accountable: Depository.new)
    create_balance(account: account, date: Date.new(2026, 3, 7), balance: 5_000)

    travel_to(zone.local(2026, 3, 9, 12)) { account.disable! }
    account.enable!

    travel_to zone.local(2026, 3, 10, 12) do
      values = BalanceSheet.new(@family).net_worth_series(period: period).values.map { |v| v.value.amount }
      assert_equal [ 5_000, 5_000, 5_000 ], values
    end
  end

  test "a disabled account without disabled_at falls back to its last update" do
    zone = @family.resolved_time_zone
    account = create_account(balance: 5_000, accountable: Depository.new)
    account.disable!
    account.update_columns(disabled_at: nil, updated_at: zone.local(2026, 3, 9, 12))

    dates = BalanceSheet::HistoricalAccountScope.new(@family).active_until_dates

    assert_equal({ account.id => Date.new(2026, 3, 8) }, dates)
  end

  test "the disabled day is the family's local day" do
    @family.update!(timezone: "Europe/Kyiv")
    account = create_account(balance: 5_000, accountable: Depository.new)
    # 23:30 UTC on Mar 8 is 01:30 on Mar 9 in Kyiv
    travel_to(Time.utc(2026, 3, 8, 23, 30)) { account.disable! }

    dates = BalanceSheet::HistoricalAccountScope.new(@family).active_until_dates

    assert_equal Date.new(2026, 3, 8), dates.fetch(account.id)
  end

  private
    def create_account(attributes = {})
      account = @family.accounts.create! name: "Test", **{ currency: "USD" }.merge(attributes)
      account
    end
end
