# The Plan page: this budget period and the goals on one page, under one nav item.
# Budgets and goals keep their own pages (/budgets, /goals); this page shows their
# summaries and links into them.
class PlansController < ApplicationController
  def show
    # The period that holds today, in the family's fiscal months
    @budget = Budget.find_or_bootstrap(Current.family, start_date: Date.current)
    if @budget
      # The summary shows the carry, so it is brought up to date (as on the budget page)
      @budget.recompute_rollover!
      @source_budget = @budget.most_recent_initialized_budget unless @budget.initialized?
    end

    @goals = Goal.active_prepared_for(Current.family)
    # Completed and archived goals are on the goals page only, so its link stays when
    # none is active
    @family_has_goals = @goals.any? || Current.family.goals.exists?
    @linkable_account_count = Goal.linkable_accounts_for(Current.family).count

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.plan"), nil ] ]
  end
end
