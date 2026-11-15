require "test_helper"

# Fiscal months that start on the 5th. On 20 March the period so far is 5 to 20 March,
# compared with the same 16 days from each earlier period start.
class Insight::Generators::SpendingAnomalyGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @family.update!(currency: "USD", use_fiscal_months: true, fiscal_month_start_day: 5)
    @account = @family.accounts.create!(name: "Checking", balance: 5_000, currency: "USD", accountable: Depository.new)
    @food = @family.categories.create!(name: "Groceries", classification: "expense")
    @rent = @family.categories.create!(name: "Rent", classification: "expense")
  end

  test "a category well above its normal by this day of the fiscal month is flagged" do
    travel_to Date.new(2026, 3, 20) do
      history(@food, 100)
      history(@rent, 1_000)
      spend(@food, 300, Date.new(2026, 3, 6))
      spend(@rent, 1_000, Date.new(2026, 3, 6))

      insight = generate.sole
      assert_equal "spending_anomaly", insight.kind
      assert_equal "spending_anomaly.above", insight.template_key
      assert_equal @food.id, insight.dedupe_key
      assert_equal Date.new(2026, 3, 5), insight.period_start
      assert_equal "high", insight.priority
      assert_equal 200, insight.facts[:deviation_pct]
      assert_equal "above", insight.metadata[:direction]
    end
  end

  test "spending in line with normal gives nothing" do
    travel_to Date.new(2026, 3, 20) do
      history(@food, 100)
      spend(@food, 110, Date.new(2026, 3, 6))

      assert_empty generate
    end
  end

  test "the first days of a fiscal month are too early to judge" do
    travel_to Date.new(2026, 3, 8) do
      history(@food, 100)
      spend(@food, 500, Date.new(2026, 3, 6))

      assert_empty generate
    end
  end

  private
    def generate
      Insight::Generators::SpendingAnomalyGenerator.new(@family).generate
    end

    # The same amount on the 6th of each of the 11 months before March 2026
    def history(category, amount)
      (1..11).each { |back| spend(category, amount, Date.new(2026, 3, 6) << back) }
    end

    def spend(category, amount, date)
      create_transaction(account: @account, amount: amount, category: category, date: date)
    end
end
