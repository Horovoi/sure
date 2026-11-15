require "test_helper"

class InvestmentFlowStatementTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    ExchangeRate.stubs(:provider).returns(nil)
    @family = families(:dylan_family)
    @account = accounts(:investment)
  end

  test "converts each contribution and withdrawal into the family currency at its own date" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: @family.currency, date: Date.current, rate: 1.5)
    flow(amount: 100, currency: "EUR", label: "Contribution")
    flow(amount: 20, currency: @family.currency, label: "Contribution")
    flow(amount: -10, currency: "EUR", label: "Withdrawal")

    totals = InvestmentFlowStatement.new(@family).period_totals(period: Period.current_month)

    assert_equal Money.new(170, @family.currency), totals.contributions
    assert_equal Money.new(15, @family.currency), totals.withdrawals
    assert_equal Money.new(155, @family.currency), totals.net_flow
  end

  test "leaves out a flow in a currency with no rate, never counting it at 1" do
    flow(amount: 100, currency: "PLN", label: "Contribution")
    flow(amount: 20, currency: @family.currency, label: "Contribution")

    totals = InvestmentFlowStatement.new(@family).period_totals(period: Period.current_month)

    assert_equal Money.new(20, @family.currency), totals.contributions
  end

  private
    def flow(amount:, currency:, label:)
      create_transaction(
        account: @account, amount: amount, currency: currency, date: Date.current,
        entryable: Transaction.new(investment_activity_label: label)
      )
    end
end
