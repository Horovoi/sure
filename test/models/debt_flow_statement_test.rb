require "test_helper"

class DebtFlowStatementTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @checking = @family.accounts.create!(name: "Checking", currency: @family.currency, balance: 5000, accountable: Depository.new)
    @credit_card = @family.accounts.create!(name: "Visa", currency: @family.currency, balance: 0, accountable: CreditCard.new, classification: :liability)
  end

  test "returns empty totals when no liability accounts exist" do
    # Remove the credit card
    @credit_card.update!(status: "closed")

    statement = DebtFlowStatement.new(@family)
    totals = statement.period_totals(period: Period.last_30_days)

    assert_equal Money.new(0, @family.currency), totals.debt_change
    assert_equal Money.new(0, @family.currency), totals.paydown
    assert_equal Money.new(0, @family.currency), totals.new_debt
    assert_empty totals.account_breakdowns
  end

  test "detects debt paydown from balance decrease" do
    # CC balance goes from 1000 to 500 over the period
    @credit_card.balances.create!(date: 20.days.ago, balance: 1000, currency: @family.currency)
    @credit_card.balances.create!(date: Date.current, balance: 500, currency: @family.currency)

    statement = DebtFlowStatement.new(@family)
    totals = statement.period_totals(period: Period.last_30_days)

    assert_equal Money.new(-500, @family.currency), totals.debt_change
    assert_equal Money.new(500, @family.currency), totals.paydown
    assert_equal Money.new(0, @family.currency), totals.new_debt
    assert_equal 1, totals.account_breakdowns.size
    assert_equal @credit_card, totals.account_breakdowns.first.account
  end

  test "detects new debt from balance increase" do
    # CC balance goes from 0 to 2000
    @credit_card.balances.create!(date: 20.days.ago, balance: 0, currency: @family.currency)
    @credit_card.balances.create!(date: Date.current, balance: 2000, currency: @family.currency)

    statement = DebtFlowStatement.new(@family)
    totals = statement.period_totals(period: Period.last_30_days)

    assert_equal Money.new(2000, @family.currency), totals.debt_change
    assert_equal Money.new(0, @family.currency), totals.paydown
    assert_equal Money.new(2000, @family.currency), totals.new_debt
  end

  test "handles mixed paydown and new debt across accounts" do
    other_cc = @family.accounts.create!(name: "Amex", currency: @family.currency, balance: 0, accountable: CreditCard.new, classification: :liability)

    # Visa: 5000 -> 2000 (paydown of 3000)
    @credit_card.balances.create!(date: 20.days.ago, balance: 5000, currency: @family.currency)
    @credit_card.balances.create!(date: Date.current, balance: 2000, currency: @family.currency)

    # Amex: 0 -> 1000 (new debt of 1000)
    other_cc.balances.create!(date: 20.days.ago, balance: 0, currency: @family.currency)
    other_cc.balances.create!(date: Date.current, balance: 1000, currency: @family.currency)

    statement = DebtFlowStatement.new(@family)
    totals = statement.period_totals(period: Period.last_30_days)

    assert_equal Money.new(-2000, @family.currency), totals.debt_change  # net: -3000 + 1000
    assert_equal Money.new(3000, @family.currency), totals.paydown
    assert_equal Money.new(1000, @family.currency), totals.new_debt
    assert_equal 2, totals.account_breakdowns.size
  end

  test "excludes loan accounts from debt flow calculation" do
    loan = @family.accounts.create!(name: "Mortgage", currency: @family.currency, balance: 100000, accountable: Loan.new, classification: :liability)

    # Loan balance changes (should be excluded)
    loan.balances.create!(date: 20.days.ago, balance: 100000, currency: @family.currency)
    loan.balances.create!(date: Date.current, balance: 99000, currency: @family.currency)

    # CC has no change
    @credit_card.balances.create!(date: 20.days.ago, balance: 500, currency: @family.currency)
    @credit_card.balances.create!(date: Date.current, balance: 500, currency: @family.currency)

    statement = DebtFlowStatement.new(@family)
    totals = statement.period_totals(period: Period.last_30_days)

    # Loan paydown should not appear; CC had no change
    assert_equal Money.new(0, @family.currency), totals.debt_change
    assert_empty totals.account_breakdowns
  end

  test "handles missing balance records gracefully" do
    # No balance records for the CC — defaults to 0
    statement = DebtFlowStatement.new(@family)
    totals = statement.period_totals(period: Period.last_30_days)

    assert_equal Money.new(0, @family.currency), totals.debt_change
    assert_empty totals.account_breakdowns
  end

  test "includes OtherLiability accounts" do
    other_liability = @family.accounts.create!(name: "IOU", currency: @family.currency, balance: 0, accountable: OtherLiability.new, classification: :liability)

    other_liability.balances.create!(date: 20.days.ago, balance: 3000, currency: @family.currency)
    other_liability.balances.create!(date: Date.current, balance: 1000, currency: @family.currency)

    statement = DebtFlowStatement.new(@family)
    totals = statement.period_totals(period: Period.last_30_days)

    # Should include OtherLiability paydown
    paydown_breakdown = totals.account_breakdowns.find { |b| b.account == other_liability }
    assert_not_nil paydown_breakdown
    assert_equal Money.new(-2000, @family.currency), paydown_breakdown.change
  end
end
