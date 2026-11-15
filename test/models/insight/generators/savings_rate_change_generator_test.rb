require "test_helper"

# Fiscal months that start on the 5th. On 20 March the last complete period is
# 5 February to 4 March, and the one before it 5 January to 4 February.
class Insight::Generators::SavingsRateChangeGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @family.update!(currency: "USD", use_fiscal_months: true, fiscal_month_start_day: 5)
    @account = @family.accounts.create!(name: "Checking", balance: 5_000, currency: "USD", accountable: Depository.new)
  end

  test "a drop of more than 10 points between the last two fiscal months is high priority" do
    travel_to Date.new(2026, 3, 20) do
      month(Date.new(2026, 1, 10), income: 1_000, spending: 500)  # 50%
      month(Date.new(2026, 2, 10), income: 1_000, spending: 900)  # 10%
      # Inside the February period (it ends on 4 March), not March's
      create_transaction(account: @account, amount: 50, date: Date.new(2026, 3, 3)) # 5%

      insight = generate.sole
      assert_equal "savings_rate_change", insight.kind
      assert_equal "savings_rate_change.down", insight.template_key
      assert_equal "high", insight.priority
      assert_equal Date.new(2026, 2, 5), insight.period_start
      assert_equal 5.0, insight.metadata[:current_rate]
      assert_equal 50.0, insight.metadata[:previous_rate]
    end
  end

  test "spending more than the income reads as such" do
    travel_to Date.new(2026, 3, 20) do
      month(Date.new(2026, 1, 10), income: 1_000, spending: 800)
      month(Date.new(2026, 2, 10), income: 1_000, spending: 1_200)

      assert_equal "savings_rate_change.down_negative", generate.sole.template_key
    end
  end

  test "a change under 5 points gives nothing" do
    travel_to Date.new(2026, 3, 20) do
      month(Date.new(2026, 1, 10), income: 1_000, spending: 800)
      month(Date.new(2026, 2, 10), income: 1_000, spending: 780)

      assert_empty generate
    end
  end

  private
    def generate
      Insight::Generators::SavingsRateChangeGenerator.new(@family).generate
    end

    def month(date, income:, spending:)
      create_transaction(account: @account, amount: -income, date: date, name: "Salary")
      create_transaction(account: @account, amount: spending, date: date, name: "Spending")
    end
end
