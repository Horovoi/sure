module RestoreLayoutPreferences
  extend ActiveSupport::Concern

  included do
    before_action :restore_active_tabs
  end

  private
    def restore_active_tabs
      @account_group_tab = account_group_tab_param || stored_account_group_tab || "asset"
    end

    def valid_account_group_tabs
      Session::ALLOWED_TABS.fetch("account_sidebar_tab")
    end

    # The stored value is checked again here, so a value written before the
    # whitelist existed cannot reach the view.
    def stored_account_group_tab
      value = Current.session&.get_preferred_tab("account_sidebar_tab")
      value if value.in?(valid_account_group_tabs)
    end

    def account_group_tab_param
      param_value = params[:account_sidebar_tab]
      return nil unless param_value.in?(valid_account_group_tabs)
      param_value
    end
end
