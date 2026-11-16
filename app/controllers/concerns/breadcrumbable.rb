module Breadcrumbable
  extend ActiveSupport::Concern

  included do
    before_action :set_breadcrumbs
  end

  private
    # The default, unless specific controller or action explicitly overrides
    def set_breadcrumbs
      @breadcrumbs = [ [ "Home", root_path ], [ controller_name.titleize, nil ] ]
    end

    # Budgets and goals live under the Plan page: Home > Plan > the given crumbs
    def plan_breadcrumbs(*trail)
      [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.plan"), plan_path ], *trail ]
    end
end
