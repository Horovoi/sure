# A monobank sync takes seconds and makes at most one request (client-info, when its
# slot is free). Statement windows are fetched by MonobankStatementFetchJob, which
# asks for a new sync as rows arrive; this sync turns the stored rows into entries
# and balances and starts the fetch chain when there is statement left to fetch.
class MonobankItem::Syncer
  include SyncStats::Collector

  class SyncError < StandardError; end

  FOLLOW_UP_WITHIN = 1.hour

  attr_reader :monobank_item

  def initialize(monobank_item)
    @monobank_item = monobank_item
  end

  def perform_sync(sync)
    # A sync queued before monobank was switched off (BankConnections) does nothing
    unless BankConnections.enabled?(:monobank)
      Rails.logger.info("MonobankItem::Syncer - monobank is switched off; sync #{sync.id} skipped")
      return
    end

    raise SyncError, I18n.t("monobank_items.errors.requires_update") if monobank_item.requires_update?

    provider = monobank_item.monobank_provider
    raise SyncError, I18n.t("monobank_items.errors.no_token") if provider.nil?

    update_status(sync, "importing")
    client_info = import_client_info(provider)
    follow_up_when_waiting(provider, client_info)

    collect_setup_stats(sync, provider_accounts: monobank_item.monobank_accounts)
    monobank_item.refresh_pending_account_setup!

    monobank_item.ensure_fetch_chain!(provider: provider)

    linked = monobank_item.monobank_accounts.joins(:account_provider)
    process_stats = {}
    errors = []

    if linked.any?
      update_status(sync, "processing")
      mark_import_started(sync)
      results = monobank_item.process_accounts
      errors.concat(results.reject { |r| r[:success] }.map { |r| { message: r[:error], category: "sync_error" } })
      process_stats = summarize(results)

      update_status(sync, "calculating")
      schedule = monobank_item.schedule_account_syncs(
        parent_sync: sync, window_start_date: sync.window_start_date, window_end_date: sync.window_end_date
      )
      errors.concat(schedule.reject { |r| r[:success] }.map { |r| { message: r[:error], category: "sync_error" } })

      account_ids = linked.includes(account_provider: :account).filter_map { |ma| ma.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "monobank")
    end

    progress = monobank_item.backfill_progress
    merge_stats(sync, process_stats.merge(
      "client_info" => client_info[:status].to_s,
      "statement_windows_remaining" => progress[:windows_remaining],
      "statement_eta_seconds" => progress[:eta_seconds],
      "chain_active" => progress[:chain_active],
      "statement_failing_products" => progress[:failing].to_a.map { |product| product[:name] }
    ))

    collect_health_stats(sync, errors: errors.presence, rate_limited: client_info[:status] == :rate_limited,
                               rate_limited_at: client_info[:status] == :rate_limited ? Time.current : nil)
    raise SyncError, errors.map { |e| e[:message] }.uniq.join(", ") if errors.any?
  end

  # Rules, transfer matching and subscriptions run here only for a sync of the
  # connection alone; inside a family sync the family does it once for everything.
  def perform_post_sync
    return unless BankConnections.enabled?(:monobank)

    latest = monobank_item.syncs.ordered.first
    return if latest.nil? || latest.parent_id.present?

    stats = latest.sync_stats || {}
    new_entries = stats["monobank_created"].to_i.positive?
    Family::ProviderPostSync.new(monobank_item.family).run(new_entries: new_entries)
  end

  private
    # The client-info slot was busy (a reconnect within a minute, or another client of
    # the token) and a new connection knows no product yet: sync again once the slot is
    # free, instead of at the next hourly sync. Only during the connection's first hour,
    # so a token another client keeps busy is not asked every minute for good.
    def follow_up_when_waiting(provider, client_info)
      return unless client_info[:status] == :rate_limited && monobank_item.monobank_accounts.none?
      return if monobank_item.created_at < FOLLOW_UP_WITHIN.ago

      DelayedSyncJob.set(wait_until: provider.next_request_slot_at(:client_info) + 1.second).perform_later(monobank_item)
    end

    def import_client_info(provider)
      MonobankItem::Importer.new(monobank_item, provider: provider).import_client_info!
    rescue Provider::Monobank::Error => e
      monobank_item.capture_error("monobank client-info request failed", e)
      raise SyncError, I18n.t("monobank_items.errors.requires_update") if monobank_item.reload.requires_update?
      raise SyncError, I18n.t("monobank_items.errors.client_info_failed") if monobank_item.monobank_accounts.none?

      { status: :failed, discovered: 0 }
    end

    def summarize(results)
      stats = results.filter_map { |r| r[:result] if r[:result].is_a?(Hash) }
      %w[claimed skipped_before_cutover pruned detached imported created].index_with do |key|
        stats.sum { |s| s[key.to_sym].to_i }
      end.transform_keys { |key| "monobank_#{key}" }
    end

    def update_status(sync, key)
      sync.update!(status_text: I18n.t("monobank_items.sync.status.#{key}")) if sync.respond_to?(:status_text)
    end

    def merge_stats(sync, stats)
      return unless sync.respond_to?(:sync_stats)

      sync.update!(sync_stats: (sync.sync_stats || {}).merge(stats))
    end
end
