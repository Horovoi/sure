require "test_helper"

class InsightTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "title and body are the English templates filled with the facts" do
    insight = build_insight(
      kind: "idle_cash",
      template_key: "idle_cash",
      facts: { "account" => "Savings", "balance" => "₴50,000.00", "idle_days" => 60 }
    )

    assert_equal "Idle cash in Savings", insight.title
    assert_equal "Savings holds ₴50,000.00 and has had no activity in the last 60 days.", insight.body
  end

  test "a pluralized title reads the count from the facts" do
    insight = build_insight(
      kind: "budget_at_risk",
      template_key: "budget_at_risk.over",
      facts: { "categories" => "Food & Drink and Rent", "count" => 2, "budget_spent_pct" => 80 }
    )

    assert_equal "2 categories need attention in your budget", insight.title
  end

  test "dismiss hides it and undismiss brings it back" do
    insight = build_insight
    insight.save!

    insight.dismiss!
    assert_not_includes @family.insights.visible, insight

    insight.undismiss!
    assert_includes @family.insights.visible, insight
  end

  test "one row per kind, subject and period" do
    build_insight.save!

    duplicate = build_insight
    assert_not duplicate.valid?

    next_period = build_insight(period_start: Date.new(2026, 12, 5))
    assert next_period.valid?
  end

  test "the feed puts high priority first" do
    low = build_insight(priority: "low", dedupe_key: "a")
    high = build_insight(priority: "high", dedupe_key: "b")
    [ low, high ].each(&:save!)

    assert_equal [ high, low ], @family.insights.ordered.to_a
  end

  test "the period runs to the end of the fiscal month" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 5)
    insight = build_insight(period_start: Date.new(2026, 11, 5))

    assert_equal Date.new(2026, 12, 4), insight.period.end_date
  end

  private
    def build_insight(**attributes)
      @family.insights.new({
        kind: "idle_cash",
        dedupe_key: "account-1",
        period_start: Date.new(2026, 11, 5),
        priority: "low",
        template_key: "idle_cash",
        facts: { "account" => "Savings", "balance" => "$5,000.00", "idle_days" => 60 },
        metadata: {},
        generated_at: Time.current
      }.merge(attributes))
    end
end
