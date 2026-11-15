# Reads the budget of the current fiscal period and gives either a warning (categories
# over or near their limit) or, once the period is at least half over, a quiet
# positive signal that everything is within its limit. Uses BudgetCategory's own
# checks, so the feed and the budget page always agree.
class Insight::Generators::BudgetInsightGenerator < Insight::Generator
  produces "budget_at_risk", "budget_on_track"

  ON_TRACK_MIN_ELAPSED = 0.5 # the positive signal only once the period is half over
  MAX_LISTED_CATEGORIES = 3

  def generate
    budget = Budget.find_for_date(family, Date.current)
    return [] unless budget&.initialized?

    parent_categories = budget.budget_categories.reject(&:subcategory?)
    over = parent_categories.select(&:over_budget_with_budget?)
    near = parent_categories.select { |bc| bc.budgeted? && bc.near_limit? }

    if over.any? || near.any?
      [ at_risk_insight(budget, over, near) ]
    elsif on_track_eligible?(budget, parent_categories)
      [ on_track_insight(budget) ]
    else
      []
    end
  end

  private
    def at_risk_insight(budget, over, near)
      flagged = over + near
      spent_pct = round(budget.percent_of_budget_spent, 0).to_i

      build_insight(
        kind: "budget_at_risk",
        priority: over.any? ? "high" : "medium",
        template_key: over.any? ? "budget_at_risk.over" : "budget_at_risk.near",
        facts: {
          categories: flagged.first(MAX_LISTED_CATEGORIES).map(&:name).to_sentence,
          count: flagged.size,
          budget_spent_pct: spent_pct
        },
        # A swing of 10 points in overall use rewrites the text; one point does not
        metadata: {
          over_category_ids: over.map(&:category_id).sort,
          near_category_ids: near.map(&:category_id).sort,
          budget_spent_pct_bucket: (spent_pct / 10) * 10,
          budget_param: budget.to_param
        },
        period_start: budget.start_date,
        dedupe_key: "budget"
      )
    end

    def on_track_insight(budget)
      spent_pct = round(budget.percent_of_budget_spent, 0).to_i

      build_insight(
        kind: "budget_on_track",
        priority: "low",
        template_key: "budget_on_track",
        facts: {
          spent: budget.actual_spending_money.format,
          budgeted: budget.budgeted_spending_money.format,
          budget_spent_pct: spent_pct
        },
        metadata: { budget_spent_pct_bucket: (spent_pct / 10) * 10, budget_param: budget.to_param },
        period_start: budget.start_date,
        dedupe_key: "budget"
      )
    end

    def on_track_eligible?(budget, parent_categories)
      return false unless parent_categories.any?(&:budgeted?)

      total_days = (budget.end_date - budget.start_date).to_i + 1
      elapsed = (Date.current - budget.start_date).to_i + 1

      elapsed.to_f / total_days >= ON_TRACK_MIN_ELAPSED
    end
end
