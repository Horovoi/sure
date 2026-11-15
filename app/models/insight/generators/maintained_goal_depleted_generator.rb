# Flags a reserve (a maintained goal) that has fallen below the level it exists to
# hold (w3-reports goal-ai-hooks, owner answer 6). High priority: a floor the user set
# on purpose is no longer there, and saying so is the point of a reserve.
#
# One row per reserve per fiscal month: a reserve can stay short for weeks while it is
# rebuilt, and a dismissal holds for the rest of the month unless the shortfall moves
# by a material step.
class Insight::Generators::MaintainedGoalDepletedGenerator < Insight::Generator
  produces "maintained_goal_depleted"

  # Several drained reserves are one problem; past two the feed scolds
  MAX_INSIGHTS = 2
  # The shortfall in steps of a tenth of the target counts as a change
  CHANGE_STEPS = 10

  def generate
    depleted_reserves.first(MAX_INSIGHTS).map do |goal|
      missing = goal.remaining_amount_money
      step = [ goal.target_amount.to_d / CHANGE_STEPS, 1 ].max

      build_insight(
        kind: "maintained_goal_depleted",
        priority: "high",
        template_key: "maintained_goal_depleted",
        facts: {
          goal: goal.name,
          missing: missing.format,
          saved: goal.current_balance_money.format,
          target: goal.target_amount_money.format
        },
        metadata: {
          goal_id: goal.id,
          missing_bucket: (missing.amount.to_d / step).ceil.to_i,
          target: round(goal.target_amount, 0)
        },
        period_start: current_period_start,
        dedupe_key: goal.id
      )
    end
  end

  private
    # Active reserves only: a paused one was shelved on purpose. Loaded through
    # Goal.prepared_for, which reads the family's shared pool once for every goal.
    # A reserve with a balance in a currency that has no rate reads as short only
    # because that balance is left out, so it is skipped (the goal page says why).
    # Largest shortfall first, then by id, so the pick is stable between runs.
    def depleted_reserves
      Goal.prepared_for(family, scope: family.goals.where(kind: "maintained", state: "active"))
        .select { |goal| goal.status == :depleted && !goal.currency_conversion_incomplete? }
        .sort_by { |goal| [ -goal.remaining_amount.to_d, goal.id ] }
    end
end
