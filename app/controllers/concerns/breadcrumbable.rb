module Breadcrumbable
  extend ActiveSupport::Concern

  included do
    before_action :set_breadcrumbs
  end

  private
    # The default, unless specific controller or action explicitly overrides. The page
    # name comes from breadcrumbs.<controller_name> when the controller's own name reads
    # wrong ("Budgetings", "Monobank Items")
    def set_breadcrumbs
      @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.#{controller_name}", default: controller_name.titleize), nil ] ]
    end

    # Budgets and goals live under the Plan page: Home > Plan > the given crumbs
    def plan_breadcrumbs(*trail)
      [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.plan"), plan_path ], *trail ]
    end
end
