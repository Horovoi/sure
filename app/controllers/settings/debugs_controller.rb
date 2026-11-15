# frozen_string_literal: true

# Settings > Debug: the DebugLogEntry event log. Super admins only; everyone else gets a
# 404, so the page does not reveal that it exists. There is no nav link: open
# /settings/debug directly.
class Settings::DebugsController < ApplicationController
  FILTER_ID_PARAMS = %i[family_id account_id user_id].freeze
  UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  layout "settings"

  before_action :require_super_admin

  def show
    filters = debug_filter_params

    @start_date = safe_parse_date(filters[:start_date])
    @end_date = safe_parse_date(filters[:end_date])

    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("settings.debugs.show.page_title"), nil ]
    ]

    scope = DebugLogEntry.recent
      .with_category(filters[:category])
      .with_level(filters[:level])
      .with_source(filters[:source])
      .with_provider_key(filters[:provider_key])

    FILTER_ID_PARAMS.each do |key|
      value = safe_uuid(filters[key])
      scope = scope.where(key => value) if value
    end

    scope = scope.where(created_at: @start_date.beginning_of_day..) if @start_date
    scope = scope.where(created_at: ...@end_date.next_day.beginning_of_day) if @end_date

    @pagy, @debug_log_entries = pagy(scope, limit: safe_per_page(50))
    @categories = DebugLogEntry.distinct.order(:category).pluck(:category)
    @levels = DebugLogEntry::LEVELS
    @sources = DebugLogEntry.distinct.order(:source).pluck(:source)
    @provider_keys = DebugLogEntry.where.not(provider_key: [ nil, "" ]).distinct.order(:provider_key).pluck(:provider_key)
  end

  private
    def require_super_admin
      head :not_found unless Current.user&.super_admin?
    end

    def safe_parse_date(value)
      Date.iso8601(value)
    rescue ArgumentError, TypeError
      nil
    end

    def safe_uuid(value)
      uuid = value.to_s.strip
      uuid.match?(UUID_FORMAT) ? uuid : nil
    end

    # Optional, flat query-string filters, so permit rather than expect (which requires
    # every key to be present)
    def debug_filter_params
      params.permit(:category, :level, :source, :provider_key, :start_date, :end_date, :page, :per_page, *FILTER_ID_PARAMS)
    end
end
