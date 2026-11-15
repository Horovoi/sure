module SettingsHelper
  # Mirrors the order and visibility of settings/_settings_nav.html.erb so the
  # previous/next links at the bottom of each page follow the sidebar. Labels
  # are keys under settings.settings_nav.
  SETTINGS_ORDER = [
    # General section
    { label: :accounts_label, path: :accounts_path },
    { label: :bank_sync_label, path: :settings_bank_sync_path, condition: :bank_connections_enabled? },
    { label: :preferences_label, path: :settings_preferences_path },
    { label: :profile_label, path: :settings_profile_path },
    { label: :security_label, path: :settings_security_path },
    # Transactions section
    { label: :categories_label, path: :categories_path },
    { label: :tags_label, path: :tags_path },
    { label: :rules_label, path: :rules_path },
    { label: :merchants_label, path: :family_merchants_path },
    # Advanced section
    { label: :budgeting_label, path: :settings_budgeting_path },
    { label: :ai_prompts_label, path: :settings_ai_prompts_path },
    { label: :llm_usage_label, path: :settings_llm_usage_path, condition: :admin_user? },
    { label: :api_keys_label, path: :settings_api_key_path },
    { label: :self_hosting_label, path: :settings_hosting_path, condition: :self_hosted? },
    { label: :imports_label, path: :imports_path },
    { label: :exports_label, path: :family_exports_path, condition: :admin_user? },
    { label: :sso_providers_label, path: :admin_sso_providers_path, condition: :super_admin_user? },
    { label: :users_label, path: :admin_users_path, condition: :super_admin_user? },
    # More section
    { label: :guides_label, path: :settings_guides_path }
  ].freeze

  def adjacent_setting(current_path, offset)
    visible_settings = SETTINGS_ORDER.select { |setting| setting[:condition].nil? || send(setting[:condition]) }
    current_index = visible_settings.index { |setting| send(setting[:path]) == current_path }
    return nil unless current_index

    adjacent_index = current_index + offset
    return nil if adjacent_index < 0 || adjacent_index >= visible_settings.size

    adjacent = visible_settings[adjacent_index]

    render partial: "settings/settings_nav_link_large", locals: {
      path: send(adjacent[:path]),
      direction: offset > 0 ? "next" : "previous",
      title: t("settings.settings_nav.#{adjacent[:label]}")
    }
  end

  def settings_section(title:, subtitle: nil, collapsible: false, open: true, &block)
    content = capture(&block)
    render partial: "settings/section", locals: { title: title, subtitle: subtitle, content: content, collapsible: collapsible, open: open }
  end

  def settings_nav_footer
    previous_setting = adjacent_setting(request.path, -1)
    next_setting = adjacent_setting(request.path, 1)

    content_tag :div, class: "hidden md:flex flex-row justify-between gap-4" do
      concat(previous_setting)
      concat(next_setting)
    end
  end

  def settings_nav_footer_mobile
    previous_setting = adjacent_setting(request.path, -1)
    next_setting = adjacent_setting(request.path, 1)

    content_tag :div, class: "md:hidden flex flex-col gap-4" do
      concat(previous_setting)
      concat(next_setting)
    end
  end

  def enable_banking_callback_url
    return callback_enable_banking_items_url if Rails.env.production?

    ENV.fetch("DEV_WEBHOOKS_URL", root_url.chomp("/")) + "/enable_banking_items/callback"
  end

  private
    def admin_user?
      Current.user&.admin? || false
    end

    def super_admin_user?
      Current.user&.super_admin? || false
    end
end
