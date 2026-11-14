class InviteCodesController < ApplicationController
  before_action :ensure_self_hosted
  # Invite codes are instance-wide (they open signup for anyone), so only a
  # super admin may list, create or delete them.
  before_action :require_super_admin

  def index
    @invite_codes = InviteCode.all
  end

  def create
    InviteCode.generate!
    redirect_back_or_to invite_codes_path, notice: "Code generated"
  end

  def destroy
    code = InviteCode.find(params[:id])
    code.destroy
    redirect_back_or_to invite_codes_path, notice: "Code deleted"
  end

  private

    def ensure_self_hosted
      redirect_to root_path unless self_hosted?
    end

    def require_super_admin
      return if Current.user&.super_admin?

      if turbo_frame_request?
        head :forbidden
      else
        redirect_to settings_hosting_path, alert: t("invite_codes.not_authorized")
      end
    end
end
