require "test_helper"

class Insight::Generators::IdleCashGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @family.update!(currency: "USD", use_fiscal_months: true, fiscal_month_start_day: 5)
  end

  test "a balance of more than a month of spending with no activity for 60 days is flagged for the fiscal month" do
    travel_to Date.new(2026, 3, 20) do
      account = cash_account(balance: 20_000)
      stub_median(4_000)

      insight = generate.sole
      assert_equal "idle_cash", insight.kind
      assert_equal account.id, insight.dedupe_key
      assert_equal Date.new(2026, 3, 5), insight.period_start
      assert_equal account.name, insight.facts[:account]
    end
  end

  test "an account with recent activity is not idle" do
    travel_to Date.new(2026, 3, 20) do
      account = cash_account(balance: 20_000)
      create_transaction(account: account, amount: 10, date: Date.new(2026, 3, 1))
      stub_median(4_000)

      assert_empty generate
    end
  end

  test "a balance under a month of spending is not flagged" do
    travel_to Date.new(2026, 3, 20) do
      cash_account(balance: 3_000)
      stub_median(4_000)

      assert_empty generate
    end
  end

  private
    def generate
      Insight::Generators::IdleCashGenerator.new(@family).generate
    end

    def cash_account(balance:)
      @family.accounts.create!(name: "Savings #{SecureRandom.hex(3)}", balance: balance, currency: "USD", accountable: Depository.new)
    end

    def stub_median(amount)
      IncomeStatement.any_instance.stubs(:median_expense).returns(amount)
    end
end
