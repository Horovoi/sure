# frozen_string_literal: true

class Settings::ApiKeysController < ApplicationController
  layout "settings"

  # show prints the key in full, and a copied key keeps working after the impersonation ends
  disallow_while_impersonating
  before_action :set_api_key, only: [ :show, :destroy ]

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "API Key", nil ]
    ]
    @current_api_key = @api_key
  end

  def new
    # Allow regeneration by not redirecting if user explicitly wants to create a new key
    # Only redirect if user stumbles onto new page without explicit intent
    redirect_to settings_api_key_path if web_api_keys.active.exists? && !params[:regenerate]
    @api_key = ApiKey.new
  end

  def create
    @plain_key = ApiKey.generate_secure_key
    @api_key = Current.user.api_keys.build(api_key_params.merge(source: "web"))
    @api_key.key = @plain_key

    # Replace the web key in one transaction, under a lock on the user, so a
    # failed save keeps the old key and two concurrent creates cannot leave
    # zero or two active keys. Mobile keys are left alone.
    created = false
    ApiKey.transaction do
      Current.user.lock!
      web_api_keys.where(revoked_at: nil).update_all(revoked_at: Time.current)
      raise ActiveRecord::Rollback unless @api_key.save

      created = true
    end

    if created
      flash[:notice] = "Your API key has been created successfully"
      redirect_to settings_api_key_path
    else
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    if @api_key&.revoke!
      flash[:notice] = "API key has been revoked successfully"
    else
      flash[:alert] = "Failed to revoke API key"
    end
    redirect_to settings_api_key_path
  end

  private

    def set_api_key
      @api_key = web_api_keys.active.first
    end

    def web_api_keys
      Current.user.api_keys.where(source: "web")
    end

    def api_key_params
      # Convert single scope value to array for storage
      permitted_params = params.require(:api_key).permit(:name, :scopes)
      if permitted_params[:scopes].present?
        permitted_params[:scopes] = [ permitted_params[:scopes] ]
      end
      permitted_params
    end
end
