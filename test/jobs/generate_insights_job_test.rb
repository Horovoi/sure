require "test_helper"

class GenerateInsightsJobTest < ActiveJob::TestCase
  # Emits one idle-cash insight for the current fiscal month; the test sets what it says
  class ProbeGenerator < Insight::Generator
    produces "idle_cash"

    cattr_accessor :balance_bucket, default: 1
    cattr_accessor :emit, default: true
    cattr_accessor :seen_date

    def generate
      self.class.seen_date = Date.current
      return [] unless emit

      [
        build_insight(
          kind: "idle_cash",
          priority: "low",
          template_key: "idle_cash",
          facts: { account: "Savings", balance: "$#{balance_bucket},000.00", idle_days: 60 },
          metadata: { account_id: "probe", balance_bucket: balance_bucket },
          period_start: current_period_start,
          dedupe_key: "probe"
        )
      ]
    end
  end

  class FailingGenerator < Insight::Generator
    produces "spending_anomaly"

    def generate
      raise "boom"
    end
  end

  setup do
    @family = families(:dylan_family)
    @family.update!(timezone: "Europe/Kyiv", use_fiscal_months: true, fiscal_month_start_day: 5)
    ProbeGenerator.balance_bucket = 1
    ProbeGenerator.emit = true
    Insight::GeneratorRegistry.stubs(:generators).returns([ ProbeGenerator ])
  end

  test "a second run adds no rows" do
    assert_difference -> { @family.insights.count }, 1 do
      GenerateInsightsJob.perform_now(@family)
      GenerateInsightsJob.perform_now(@family)
    end
  end

  test "it runs in the family's time zone, so the fiscal month is Kyiv's" do
    # 22:30 UTC on 4 November is 00:30 on 5 November in Kyiv: the first day of the period
    travel_to Time.utc(2026, 11, 4, 22, 30) do
      GenerateInsightsJob.perform_now(@family)
    end

    assert_equal Date.new(2026, 11, 5), ProbeGenerator.seen_date
    assert_equal Date.new(2026, 11, 5), @family.insights.sole.period_start
  end

  test "a dismissed insight stays dismissed while its numbers are the same" do
    GenerateInsightsJob.perform_now(@family)
    @family.insights.sole.dismiss!

    GenerateInsightsJob.perform_now(@family)

    assert @family.insights.sole.dismissed?
  end

  test "a dismissed insight comes back when its numbers change materially" do
    GenerateInsightsJob.perform_now(@family)
    @family.insights.sole.dismiss!

    ProbeGenerator.balance_bucket = 2
    GenerateInsightsJob.perform_now(@family)

    insight = @family.insights.sole
    assert_not insight.dismissed?
    assert_equal "$2,000.00", insight.facts["balance"]
  end

  test "a visible insight that is no longer emitted is cleared, a dismissed one is kept" do
    GenerateInsightsJob.perform_now(@family)
    ProbeGenerator.emit = false

    GenerateInsightsJob.perform_now(@family)
    assert_equal 0, @family.insights.count

    ProbeGenerator.emit = true
    GenerateInsightsJob.perform_now(@family)
    @family.insights.sole.dismiss!
    ProbeGenerator.emit = false

    GenerateInsightsJob.perform_now(@family)
    assert @family.insights.sole.dismissed?
  end

  test "a failing generator keeps its own insights and does not stop the others" do
    @family.insights.create!(kind: "spending_anomaly", dedupe_key: "cat", period_start: Date.current, priority: "medium",
                             template_key: "spending_anomaly.above", facts: {}, generated_at: Time.current)
    Insight::GeneratorRegistry.stubs(:generators).returns([ FailingGenerator, ProbeGenerator ])

    assert_difference -> { DebugLogEntry.where(category: "insights").count }, 1 do
      GenerateInsightsJob.perform_now(@family)
    end

    assert_equal %w[idle_cash spending_anomaly], @family.insights.pluck(:kind).sort
  end

  test "dismissed insights of old fiscal months are pruned" do
    travel_to Date.new(2026, 11, 20) do
      old = @family.insights.create!(kind: "idle_cash", dedupe_key: "old", period_start: Date.new(2026, 8, 5), priority: "low",
                                     template_key: "idle_cash", facts: {}, generated_at: Time.current, dismissed_at: Time.current)
      recent = @family.insights.create!(kind: "idle_cash", dedupe_key: "recent", period_start: Date.new(2026, 9, 5), priority: "low",
                                        template_key: "idle_cash", facts: {}, generated_at: Time.current, dismissed_at: Time.current)

      GenerateInsightsJob.perform_now(@family)

      assert_not Insight.exists?(old.id)
      assert Insight.exists?(recent.id)
    end
  end

  test "without a family it queues one run per family" do
    assert_enqueued_jobs Family.count, only: GenerateInsightsJob do
      GenerateInsightsJob.perform_now
    end
  end
end
