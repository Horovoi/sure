require "test_helper"

class Insight::Generators::NetWorthMilestoneGeneratorTest < ActiveSupport::TestCase
  Point = Struct.new(:date, :value)
  Series = Struct.new(:values)

  setup do
    @family = families(:dylan_family)
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 5)
  end

  test "crossing a milestone during the fiscal month is celebrated, with no period" do
    travel_to Date.new(2026, 3, 20) do
      stub_series(from: 95_000, to: 101_000)

      insight = generate.sole
      assert_equal "net_worth_milestone", insight.kind
      assert_equal "100000", insight.dedupe_key
      assert_nil insight.period_start
      assert_equal 100_000, insight.metadata[:milestone]
    end
  end

  test "the highest milestone crossed is the one named" do
    travel_to Date.new(2026, 3, 20) do
      stub_series(from: 240_000, to: 510_000)

      assert_equal "500000", generate.sole.dedupe_key
    end
  end

  test "no milestone crossed gives nothing" do
    travel_to Date.new(2026, 3, 20) do
      stub_series(from: 101_000, to: 120_000)

      assert_empty generate
    end
  end

  test "the series starts the day before the fiscal month" do
    travel_to Date.new(2026, 3, 20) do
      BalanceSheet.any_instance.expects(:net_worth_series)
        .with { |options| options[:period].start_date == Date.new(2026, 3, 4) && options[:period].end_date == Date.current }
        .returns(Series.new([]))

      assert_empty generate
    end
  end

  private
    def generate
      Insight::Generators::NetWorthMilestoneGenerator.new(@family).generate
    end

    def stub_series(from:, to:)
      values = [ Point.new(Date.new(2026, 3, 4), Money.new(from, @family.currency)), Point.new(Date.current, Money.new(to, @family.currency)) ]
      BalanceSheet.any_instance.stubs(:net_worth_series).returns(Series.new(values))
    end
end
