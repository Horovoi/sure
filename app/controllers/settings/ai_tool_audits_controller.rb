# Settings > Advanced > AI tool calls: every tool call the chat and /mcp made for this family, newest first, so a
# wrong write can be found and reverted by hand (or by asking Claude) from its ids and before snapshot. Read-only:
# there is no automatic revert. Family admins and super admins only; anyone else gets a 404.
class Settings::AiToolAuditsController < ApplicationController
  layout "settings"

  PER_PAGE_OPTIONS = [ 10, 20, 30, 50, 100 ].freeze
  DEFAULT_PER_PAGE = 50

  before_action :require_admin

  def index
    @breadcrumbs = [
      [ t(".breadcrumb_home"), root_path ],
      [ t(".page_title"), nil ]
    ]

    audits = Current.family.ai_tool_audits
    @tool_names = audits.distinct.order(:tool_name).pluck(:tool_name)
    @writes_only = params[:writes] == "1"
    @tool = params[:tool].presence_in(@tool_names)

    scope = audits.includes(:user).newest_first
    scope = scope.writes if @writes_only
    scope = scope.for_tool(@tool) if @tool

    @pagy, @audits = pagy(scope, limit: per_page)
  end

  private
    def require_admin
      raise ActiveRecord::RecordNotFound unless Current.user&.admin?
    end

    def per_page
      requested = params[:per_page].to_i
      PER_PAGE_OPTIONS.include?(requested) ? requested : DEFAULT_PER_PAGE
    end
end
