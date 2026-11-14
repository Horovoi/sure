# Restricts actions to family admins. Non-admins are sent to their profile
# page, which every member can open, so the redirect can never loop.
module FamilyAdminRequired
  extend ActiveSupport::Concern

  class_methods do
    def require_family_admin(**options)
      before_action :require_family_admin!, **options
    end
  end

  private
    def require_family_admin!
      return if Current.user&.admin?

      if request.format.json?
        head :forbidden
      else
        redirect_to settings_profile_path, alert: t("shared.require_family_admin.not_authorized")
      end
    end
end
