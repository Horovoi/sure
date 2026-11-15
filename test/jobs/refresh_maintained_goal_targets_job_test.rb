require "test_helper"

# The job runs daily and acts for a family only on the first day of its fiscal month,
# in the family's time zone. Baselined on fiscal months that start on the 5th.
class RefreshMaintainedGoalTargetsJobTest < ActiveJob::TestCase
  # 00:30 on 5 November 2026 in Kyiv (UTC+2): the first day of the fiscal month there,
  # still the 4th in UTC
  FISCAL_START_IN_KYIV = Time.utc(2026, 11, 4, 22, 30)

  setup do
    @family = families(:dylan_family)
    @family.update!(timezone: "Europe/Kyiv", use_fiscal_months: true, fiscal_month_start_day: 5)
  end

  test "a reserve's floor follows the median monthly spend" do
    goal = reserve(months: 6, target: 1_000)
    stub_median(500)

    travel_to(FISCAL_START_IN_KYIV) { RefreshMaintainedGoalTargetsJob.perform_now }

    assert_equal BigDecimal("3000"), goal.reload.target_amount.to_d
  end

  test "it acts on the first day of the fiscal month in the family's time zone, not UTC's" do
    goal = reserve(months: 6, target: 1_000)
    stub_median(500)

    # 23:30 UTC on the 5th is already the 6th in Kyiv
    travel_to(Time.utc(2026, 11, 5, 23, 30)) { RefreshMaintainedGoalTargetsJob.perform_now }
    assert_equal BigDecimal("1000"), goal.reload.target_amount.to_d

    travel_to(FISCAL_START_IN_KYIV) { RefreshMaintainedGoalTargetsJob.perform_now }
    assert_equal BigDecimal("3000"), goal.reload.target_amount.to_d
  end

  test "it does nothing on a day inside the fiscal month" do
    goal = reserve(months: 6, target: 1_000)
    stub_median(500)

    travel_to(Time.utc(2026, 11, 15, 12)) { RefreshMaintainedGoalTargetsJob.perform_now }

    assert_equal BigDecimal("1000"), goal.reload.target_amount.to_d
  end

  test "without fiscal months it acts on the 1st" do
    @family.update!(use_fiscal_months: false)
    goal = reserve(months: 6, target: 1_000)
    stub_median(500)

    travel_to(Time.utc(2026, 12, 1, 6)) { RefreshMaintainedGoalTargetsJob.perform_now }

    assert_equal BigDecimal("3000"), goal.reload.target_amount.to_d
  end

  # A family with no spending history would compute a floor of zero, which violates
  # target_amount > 0 and would read as "your reserve is complete"
  test "a median of zero leaves the target standing" do
    goal = reserve(months: 6, target: 1_000)
    stub_median(0)

    travel_to(FISCAL_START_IN_KYIV) { RefreshMaintainedGoalTargetsJob.perform_now }

    assert_equal BigDecimal("1000"), goal.reload.target_amount.to_d
  end

  test "fixed-target reserves and one-off goals are left alone" do
    fixed = reserve(months: nil, target: 2_000, mode: "fixed")
    one_off = @family.goals.create!(
      name: "Trip", target_amount: 800, currency: "USD"
    ) { |g| g.goal_accounts.build(account: account_for("Trip")) }
    stub_median(500)

    travel_to(FISCAL_START_IN_KYIV) { RefreshMaintainedGoalTargetsJob.perform_now }

    assert_equal BigDecimal("2000"), fixed.reload.target_amount.to_d
    assert_equal BigDecimal("800"), one_off.reload.target_amount.to_d
  end

  test "an archived reserve is not refreshed" do
    goal = reserve(months: 6, target: 1_000)
    goal.archive!
    stub_median(500)

    travel_to(FISCAL_START_IN_KYIV) { RefreshMaintainedGoalTargetsJob.perform_now }

    assert_equal BigDecimal("1000"), goal.reload.target_amount.to_d
  end

  test "a target already equal to the computed figure is not rewritten" do
    goal = reserve(months: 6, target: 3_000)
    stub_median(500)

    assert_no_changes -> { goal.reload.updated_at } do
      travel_to(FISCAL_START_IN_KYIV) { RefreshMaintainedGoalTargetsJob.perform_now }
    end
  end

  # A reserve silently frozen at a stale floor is invisible to the user, so the failure
  # is logged where a super admin sees it
  test "a write that fails validation is recorded for support" do
    goal = reserve(months: 6, target: 1_000)
    stub_median(500)
    Goal.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(goal))

    assert_difference -> { DebugLogEntry.where(category: "goals").count }, 1 do
      travel_to(FISCAL_START_IN_KYIV) { RefreshMaintainedGoalTargetsJob.perform_now }
    end

    assert_equal BigDecimal("1000"), goal.reload.target_amount.to_d
  end

  test "the job is scheduled daily on the scheduled queue as an ActiveJob" do
    entry = YAML.safe_load_file(Rails.root.join("config/schedule.yml")).fetch("refresh_maintained_goal_targets")

    assert_equal "RefreshMaintainedGoalTargetsJob", entry["class"]
    assert_equal "scheduled", entry["queue"]
    assert_equal true, entry["active_job"]
    assert_match(/\A\d+ \d+ \* \* \*/, entry["cron"])
  end

  private
    def account_for(name)
      Account.create!(
        family: @family, accountable: Depository.new,
        name: "#{name} Pot", currency: "USD", balance: 1_000
      )
    end

    # `target` is the figure the reserve starts from, written past the callback that
    # derives a months-mode floor on create: these tests are about what the job does
    # to an existing target
    def reserve(months:, target:, mode: "months_of_expenses", name: "Emergency")
      goal = @family.goals.create!(
        name: name, target_amount: target, currency: "USD",
        kind: "maintained", target_mode: mode, target_months: months
      ) { |g| g.goal_accounts.build(account: account_for(name)) }

      goal.update_column(:target_amount, target)
      goal.reload
    end

    def stub_median(amount)
      IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal(amount.to_s))
    end
end
