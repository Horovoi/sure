# Keeps "N months of expenses" reserves current: what covered six months last year does
# not cover six months today. Scheduled daily (config/schedule.yml); for each family it
# acts only on the first day of the family's fiscal month, in the family's time zone, so
# a full fiscal month of spending has landed and the target moves once a month.
#
# Writes target_amount rather than deriving a target on read, so every aggregate that
# reads it keeps working (see Goal::TARGET_MODES).
class RefreshMaintainedGoalTargetsJob < ApplicationJob
  queue_as :scheduled

  def perform
    goals = Goal.not_released.where(kind: "maintained", target_mode: "months_of_expenses").includes(:family)

    goals.group_by(&:family).each do |family, family_goals|
      in_time_zone_of(family) do
        next unless fiscal_month_starts_today?(family)

        family_goals.each { |goal| refresh(goal) }
      end
    end
  end

  private
    # The job loops over families itself, so it has no single family to run in
    def family_for_time_zone
      nil
    end

    def fiscal_month_starts_today?(family)
      today = Date.current
      family.budget_period_start_for(today) == today
    end

    def refresh(goal)
      previous = goal.target_amount.to_d
      updated = goal.refresh_target_from_expenses!
      return if updated.nil?

      Rails.logger.info("RefreshMaintainedGoalTargetsJob: goal #{goal.id} target #{previous} -> #{updated}")
    rescue ActiveRecord::RecordInvalid => e
      # The reserve keeps its target. Logged where a super admin sees it: a floor that
      # quietly stopped moving is invisible to the user.
      DebugLogEntry.capture(
        category: "goals",
        level: "error",
        message: "Could not refresh maintained goal target: #{e.message}",
        source: self.class.name,
        family: goal.family,
        metadata: { goal_id: goal.id, target_months: goal.target_months, previous_target_amount: previous.to_s }
      )
    end
end
