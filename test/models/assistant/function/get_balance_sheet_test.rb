require "test_helper"

class Assistant::Function::GetBalanceSheetTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @fn = Assistant::Function::GetBalanceSheet.new(@user)
  end

  test "has correct name and is not strict" do
    assert_equal "get_balance_sheet", @fn.name
    refute @fn.to_definition[:strict]
  end

  test "default call keeps the established shape with numeric history" do
    result = @fn.call

    assert result[:net_worth][:current].present?
    assert result[:assets].key?(:monthly_history)
    assert result[:liabilities].key?(:monthly_history)
    assert result[:insights][:debt_to_asset_ratio].present?
    assert_equal "1 month", result[:net_worth][:monthly_history][:interval]
    assert(result[:net_worth][:monthly_history][:values].all? { |v| v.is_a?(Numeric) })
  end

  test "named period bounds the history series" do
    series = @fn.call("period" => "last_30_days")[:net_worth][:monthly_history]

    assert series[:start_date] >= 31.days.ago.to_date
  end

  test "the fiscal month period starts on the family's fiscal start day without a session" do
    @user.family.update!(use_fiscal_months: true, fiscal_month_start_day: 25)
    Current.session = nil

    period = @fn.send(:named_period, "fiscal_current_month")

    assert_equal @user.family.budget_period_start_for(Date.current), period.start_date
    assert_equal Date.current, period.end_date
  end

  test "invalid custom dates return an invalid_date error with a hint" do
    result = @fn.call("start_date" => "not-a-date", "end_date" => "2024-01-01")

    assert_equal "invalid_date", result[:error]
    assert result[:hint].present?
  end

  test "a reversed custom range returns the structured error" do
    assert_equal "invalid_date", @fn.call("start_date" => "2025-06-01", "end_date" => "2025-01-01")[:error]
  end

  test "too many points returns an error instead of a giant series" do
    result = @fn.call("start_date" => "2015-01-01", "end_date" => "2025-01-01", "interval" => "1 day")

    assert_equal "too_many_points", result[:error]
  end

  test "a family with no assets gets no debt ratio instead of a division by zero" do
    user = users(:empty)

    result = Assistant::Function::GetBalanceSheet.new(user).call

    assert_not result[:insights].key?(:debt_to_asset_ratio)
  end

  # -- w3-reports exclude-from-reports ---------------------------------------

  test "an account excluded from reports is left out of net worth and its history" do
    family = @user.family
    before = family.balance_sheet.net_worth
    excluded = accounts(:depository)
    excluded.update!(exclude_from_reports: true)

    result = Assistant::Function::GetBalanceSheet.new(@user).call("period" => "last_30_days")
    expected = BalanceSheet.new(family.reload)

    assert_not_equal before, expected.net_worth
    assert_equal expected.net_worth_money.format, result[:net_worth][:current]
    assert_equal expected.assets.total_money.format, result[:assets][:current]
    assert_not_includes BalanceSheet::HistoricalAccountScope.new(family).account_ids, excluded.id
  end
end
