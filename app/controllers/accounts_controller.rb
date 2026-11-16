class AccountsController < ApplicationController
  require_bank_connections only: :select_provider
  before_action :set_account, only: %i[sync sparkline toggle_active show destroy unlink confirm_unlink select_provider clear_filter set_default remove_default toggle_exclude_from_reports]
  include Periodable

  def index
    # Accounts of a provider that is off have no provider card, so they are listed with
    # the manual ones, where they can be unlinked.
    @manual_accounts = family.accounts
          .listable
          .outside_enabled_providers
          .order(:name)
          .preload(:accountable, :account_providers)
          .with_attached_logo
    Account.preload_syncing(@manual_accounts)
    @plaid_items = provider_items(family.plaid_items, :plaid).includes(:syncs, :plaid_accounts)
    @lunchflow_items = provider_items(family.lunchflow_items, :lunchflow).includes(:syncs, :lunchflow_accounts)
    @enable_banking_items = provider_items(family.enable_banking_items, :enable_banking).includes(:syncs)
    @coinstats_items = provider_items(family.coinstats_items, :coinstats).includes(:coinstats_accounts, :accounts, :syncs)
    @coinbase_items = provider_items(family.coinbase_items, :coinbase).includes(:coinbase_accounts, :accounts, :syncs)
    # Providers that render their own item card (BankConnections generic_listing)
    @generic_provider_items = BankConnections.enabled_providers.select(&:generic_listing?).flat_map do |provider|
      family.public_send(provider.association).ordered.to_a
    end

    # Build sync stats maps for all providers
    build_sync_stats_maps

    # Prevent Turbo Drive from caching this page to ensure fresh account lists
    expires_now
    render layout: "settings"
  end

  def new
    # The connection configs of the enabled providers with any credentials configured
    @provider_configs = Provider::Factory.enabled_connection_configs(family: family)
  end

  def sync_all
    family.sync_later
    redirect_to accounts_path, notice: t("accounts.sync_all.syncing")
  end

  def show
    @chart_view = params[:chart_view].presence || "balance"
    @tab = params[:tab].presence
    @q = account_search_params
    # A split shows as its parts, grouped under the parent (which is excluded while split)
    entries = @account.entries.where(excluded: false).search(@q).reverse_chronological.includes(parent_entry: :child_entries)

    @pagy, @entries = pagy(entries, limit: safe_per_page)

    @activity_feed_data = Account::ActivityFeedData.new(@account, @entries)
    # w2-transfers transfer-hints: rows with a likely transfer counterpart show "Transfer?"
    @transfer_hint_transaction_ids = Current.family.transaction_ids_with_transfer_candidates(@entries.select(&:transaction?).map(&:entryable))
  end

  def sync
    unless @account.syncing?
      enabled_links = @account.account_providers.select do |account_provider|
        BankConnections.enabled_account_class_names.include?(account_provider.provider_type)
      end

      if enabled_links.any?
        # Sync the provider items of this account (enabled providers only).
        # Each provider item will trigger an account sync when complete
        enabled_links.each do |account_provider|
          item = account_provider.adapter&.item
          item&.sync_later if item && !item.syncing?
        end
      else
        # Manual accounts, and accounts of a provider that is off, just need balance materialization
        @account.sync_later
      end
    end

    redirect_to account_path(@account)
  end

  def sparkline
    etag_key = @account.family.build_cache_key("#{@account.id}_sparkline", invalidate_on_data_updates: true)

    # Short-circuit with 304 Not Modified when the client already has the latest version.
    # We defer the expensive series computation until we know the content is stale.
    if stale?(etag: etag_key, last_modified: @account.family.latest_sync_completed_at)
      @sparkline_series = @account.sparkline_series
      render layout: false
    end
  end

  def toggle_active
    if @account.active?
      @account.disable!
    elsif @account.disabled?
      @account.enable!
      # Family syncs skip disabled accounts, so its balances and holdings may be out of date
      @account.sync_later
    end
    redirect_to accounts_path
  end

  # w3-reports exclude-from-reports: keeps the account out of every report and total, or
  # puts it back. The account stays active and listed.
  def toggle_exclude_from_reports
    if @account.pending_deletion?
      redirect_back_or_to accounts_path, alert: t("accounts.exclude_from_reports.pending_deletion")
      return
    end

    @account.update!(exclude_from_reports: !@account.exclude_from_reports?)
    notice = if @account.exclude_from_reports?
      t("accounts.exclude_from_reports.excluded", name: @account.name)
    else
      t("accounts.exclude_from_reports.included", name: @account.name)
    end
    redirect_back_or_to account_path(@account), notice: notice
  end

  # w2-transfers default-account: the new-transaction and new-transfer forms preselect it
  def set_default
    unless @account.eligible_as_default?
      redirect_back_or_to account_path(@account), alert: t("accounts.set_default.not_eligible")
      return
    end

    Current.user.update!(default_account: @account)
    redirect_back_or_to account_path(@account), notice: t("accounts.set_default.success", name: @account.name)
  end

  def remove_default
    Current.user.update!(default_account: nil) if Current.user.default_account_id == @account.id
    redirect_back_or_to account_path(@account), notice: t("accounts.remove_default.success")
  end

  def destroy
    if @account.linked?
      redirect_to account_path(@account), alert: t("accounts.destroy.cannot_delete_linked")
    else
      @account.destroy_later
      redirect_to accounts_path, notice: t("accounts.destroy.success", type: @account.accountable_type)
    end
  end

  def confirm_unlink
    unless @account.linked?
      redirect_to account_path(@account), alert: t("accounts.unlink.not_linked")
    end
  end

  def unlink
    unless @account.linked?
      redirect_to account_path(@account), alert: t("accounts.unlink.not_linked")
      return
    end

    begin
      # Keeps today's balance and the history; detaches holdings; removes the links
      Account::ProviderLink.unlink!(@account)

      redirect_to accounts_path, notice: t("accounts.unlink.success")
    rescue ActiveRecord::RecordInvalid => e
      redirect_to account_path(@account), alert: t("accounts.unlink.error", error: e.message)
    rescue StandardError => e
      Rails.logger.error "Failed to unlink account #{@account.id}: #{e.message}"
      redirect_to account_path(@account), alert: t("accounts.unlink.error", error: t("accounts.unlink.generic_error"))
    end
  end

  def clear_filter
    q_params = account_search_params

    param_key = params[:param_key]
    param_value = params[:param_value]

    if q_params[param_key].is_a?(Array)
      q_params[param_key].delete(param_value)
      q_params.delete(param_key) if q_params[param_key].empty?
    else
      q_params.delete(param_key)
    end
    q_params.delete("amount_operator") if param_key == "amount"

    redirect_params = account_page_state_params
    redirect_params[:q] = q_params if q_params.present?

    redirect_to account_path(@account, redirect_params)
  end

  def select_provider
    if @account.linked?
      redirect_to account_path(@account), alert: t("accounts.select_provider.already_linked")
      return
    end

    account_type_name = @account.accountable_type

    # Get all available provider configs dynamically for this account type
    provider_configs = Provider::Factory.connection_configs_for_account_type(
      account_type: account_type_name,
      family: family
    )

    # Build available providers list with paths resolved for this specific account
    # Filter out providers that don't support linking to existing accounts
    @available_providers = provider_configs.filter_map do |config|
      next unless config[:existing_account_path].present?
      {
        name: config[:name],
        key: config[:key],
        description: config[:description],
        path: config[:existing_account_path].call(@account.id)
      }
    end

    if @available_providers.empty?
      redirect_to account_path(@account), alert: t("accounts.select_provider.no_providers")
    end
  end

  private
    def family
      Current.family
    end

    def provider_items(items, key)
      BankConnections.enabled?(key) ? items.ordered : items.none
    end

    def set_account
      @account = family.accounts.find(params[:id])
    end

    def account_search_params
      cleaned = params.fetch(:q, {}).permit(
        :start_date, :end_date, :search, :amount, :amount_operator,
        categories: [], merchants: [], types: [], tags: [], status: [],
        attachment_status: [], # w3-toolstrx transaction-attachments
        reconcile_status: [] # w3-toolstrx reconciliation-status
      ).to_h.compact_blank
      cleaned.delete("amount_operator") if cleaned["amount"].blank?
      cleaned
    end

    def account_page_state_params
      params.permit(:tab, :chart_view, :period, :start_date, :end_date, :per_page).to_h.compact_blank
    end

    # Builds sync stats maps for all provider types to avoid N+1 queries in views
    def build_sync_stats_maps
      # Plaid sync stats
      @plaid_sync_stats_map = {}
      @plaid_items.each do |item|
        latest_sync = item.syncs.ordered.first
        @plaid_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Lunchflow sync stats
      @lunchflow_sync_stats_map = {}
      @lunchflow_items.each do |item|
        latest_sync = item.syncs.ordered.first
        @lunchflow_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Enable Banking sync stats
      @enable_banking_sync_stats_map = {}
      @enable_banking_items.each do |item|
        latest_sync = item.syncs.ordered.first
        @enable_banking_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # CoinStats sync stats
      @coinstats_sync_stats_map = {}
      @coinstats_items.each do |item|
        latest_sync = item.syncs.ordered.first
        @coinstats_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Coinbase sync stats
      @coinbase_sync_stats_map = {}
      @coinbase_unlinked_count_map = {}
      @coinbase_items.each do |item|
        latest_sync = item.syncs.ordered.first
        @coinbase_sync_stats_map[item.id] = latest_sync&.sync_stats || {}

        # Count unlinked accounts
        count = item.coinbase_accounts
          .left_joins(:account_provider)
          .where(account_providers: { id: nil })
          .count
        @coinbase_unlinked_count_map[item.id] = count
      end
    end
end
