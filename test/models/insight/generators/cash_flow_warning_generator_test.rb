require "test_helper"

class Insight::Generators::CashFlowWarningGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @family.update!(currency: "USD", use_fiscal_months: true, fiscal_month_start_day: 5)
  end

  test "cash that a typical month of spending would overdraw gives a high-priority warning" do
    travel_to Date.new(2026, 3, 20) do
      cash_account(balance: 1_000)
      stub_median(4_000)

      insight = generate.sole
      assert_equal "cash_flow_warning", insight.kind
      assert_equal "cash_flow_warning.negative", insight.template_key
      assert_equal "high", insight.priority
      assert_equal Date.new(2026, 3, 5), insight.period_start
      assert insight.metadata[:negative]
    end
  end

  test "a bill due in the window counts on its date" do
    travel_to Date.new(2026, 3, 20) do
      cash_account(balance: 4_000)
      stub_median(3_000)
      # Without the bill the low point is 1,000, above the 750 line (a quarter of 3,000)
      assert_empty generate

      # A bill larger than the typical month takes the low point to 400 on 25 March
      @family.recurring_transactions.create!(
        name: "Rent", amount: 3_600, currency: "USD", expected_day_of_month: 25,
        last_occurrence_date: Date.new(2026, 2, 25), next_expected_date: Date.new(2026, 3, 25),
        status: "active", manual: true
      )

      insight = generate.sole
      assert_equal "cash_flow_warning.low", insight.template_key
      assert_equal "medium", insight.priority
    end
  end

  test "cash that covers the month gives nothing" do
    travel_to Date.new(2026, 3, 20) do
      cash_account(balance: 20_000)
      stub_median(4_000)

      assert_empty generate
    end
  end

  test "an account excluded from reports is not counted" do
    travel_to Date.new(2026, 3, 20) do
      cash_account(balance: 1_000)
      cash_account(balance: 50_000).update!(exclude_from_reports: true)
      stub_median(4_000)

      assert_equal "cash_flow_warning.negative", generate.sole.template_key
    end
  end

  # The owner's month: cash of about 18k, spending about 90k and income about 127k
  test "typical income keeps a household that spends more than its cash each month from a false alarm" do
    travel_to Date.new(2026, 3, 20) do
      cash_account(balance: 17_871)
      stub_median(90_000)
      IncomeStatement.any_instance.stubs(:median_income).returns(126_557)

      assert_empty generate
    end
  end

  test "a salary due in the window counts on its date" do
    travel_to Date.new(2026, 3, 20) do
      cash_account(balance: 1_000)
      stub_median(4_000)
      IncomeStatement.any_instance.stubs(:median_income).returns(4_000)
      @family.recurring_transactions.create!(
        name: "Salary", amount: -4_000, currency: "USD", expected_day_of_month: 21,
        last_occurrence_date: Date.new(2026, 2, 21), next_expected_date: Date.new(2026, 3, 21),
        status: "active", manual: true
      )

      # The salary arrives the next day, before the month's spending wears the cash down
      assert_empty generate
    end
  end

  private
    def generate
      Insight::Generators::CashFlowWarningGenerator.new(@family).generate
    end

    def cash_account(balance:)
      @family.accounts.create!(name: "Cash #{SecureRandom.hex(3)}", balance: balance, currency: "USD", accountable: Depository.new)
    end

    def stub_median(amount)
      IncomeStatement.any_instance.stubs(:median_expense).returns(amount)
    end
end
