# Writes what monobank returned into the connection's records. Makes no entries:
# MonobankAccount::Processor turns stored rows into entries during a sync.
#
#   import_client_info!   one client-info request: products and their balances
#   store_window!         the rows of one statement request, and the fetch cursors
class MonobankItem::Importer
  attr_reader :monobank_item, :provider

  def initialize(monobank_item, provider: monobank_item.monobank_provider)
    @monobank_item = monobank_item
    @provider = provider
  end

  # Returns :imported, or :rate_limited when the client-info slot is not free (the
  # stored snapshot is kept). A refused token marks the connection requires_update and
  # raises; any other provider error raises.
  def import_client_info!
    client_info = provider.get_client_info
    monobank_item.upsert_client_info!(client_info)

    discovered = 0
    provider.get_accounts(client_info: client_info).each do |data|
      monobank_account = monobank_item.monobank_accounts.find_or_initialize_by(account_id: data[:id].to_s)
      discovered += 1 if monobank_account.new_record?
      monobank_account.upsert_monobank_snapshot!(data)
    end

    monobank_item.refresh_pending_account_setup!
    { status: :imported, discovered: discovered }
  rescue Provider::Monobank::RateLimitError
    { status: :rate_limited, discovered: 0 }
  rescue Provider::Monobank::Error => e
    mark_requires_update! if auth_failure?(e)
    raise
  end

  # Stores the rows of one statement request for window (a FetchPlan::Window) and moves
  # the cursors. Returns :complete when the window is done, :partial when monobank
  # returned a full page and the rest of the window is fetched as the next page.
  def store_window!(window, rows, now: Time.current)
    rows = Array(rows).select { |row| row.is_a?(Hash) }.map { |row| row.to_h.stringify_keys }
    monobank_account = window.monobank_account
    result = nil

    monobank_account.with_lock do
      by_id = Array(monobank_account.raw_transactions_payload).index_by { |row| row_key(row) }
      fetched_ids = rows.map { |row| row_key(row) }
      kept_rows = monobank_item.include_pending_holds? ? rows : rows.reject { |row| hold?(row) }
      kept_rows.each { |row| by_id[row_key(row)] = row }

      if window.kind.in?(%i[first forward gap])
        monobank_account.statement_synced_through = [ monobank_account.statement_synced_through, window.to ].compact.max
      end

      next_page_to = next_page_to(monobank_account, window, rows)
      if next_page_to
        monobank_account.page_from = window.from
        monobank_account.page_to = next_page_to
        monobank_account.page_kind = window.kind.to_s
        monobank_account.page_seen_ids = (Array(monobank_account.page_seen_ids) + fetched_ids).uniq
        result = :partial
      else
        seen_ids = (Array(monobank_account.page_seen_ids) + fetched_ids).to_set
        complete_window(monobank_account, window, by_id, seen_ids, now)
        result = :complete
      end

      by_id.reject! { |_, row| hold?(row) && (time = row_time(row)) && time < now - MonobankItem::FetchPlan::HOLD_RETENTION }
      monobank_account.raw_transactions_payload = by_id.values
      monobank_account.fetch_failures = 0
      monobank_account.next_fetch_after = nil
      monobank_account.save!
    end

    result
  end

  # Records a failed request for one product: it is skipped for 2**n minutes
  def record_fetch_failure!(monobank_account, error, now: Time.current)
    failures = monobank_account.fetch_failures + 1
    delay = [ (2**failures).minutes, 1.day ].min
    monobank_account.update!(fetch_failures: failures, next_fetch_after: now + delay)
    monobank_item.capture_error("monobank statement request failed", error, monobank_account: monobank_account, level: "warn",
                                metadata: { fetch_failures: failures, retry_after: (now + delay).iso8601 })
  end

  # monobank refused a backfill window (history limit reached): stop the backfill there
  def record_history_limit!(monobank_account, window, error)
    monobank_account.update!(history_complete: true, page_from: nil, page_to: nil, page_kind: nil, page_seen_ids: [])
    DebugLogEntry.capture(
      category: "provider_sync",
      level: "info",
      message: "monobank refused an older statement window; history import stops there",
      source: self.class.name,
      provider_key: "monobank",
      family: monobank_item.family,
      account_provider: monobank_account.account_provider,
      metadata: { monobank_item_id: monobank_item.id, monobank_account_id: monobank_account.id,
                  window_from: window.from.iso8601, window_to: window.to.iso8601, error_message: error.message }
    )
  end

  def mark_requires_update!
    monobank_item.update!(status: :requires_update)
  end

  def auth_failure?(error)
    error.failure_code.in?(%i[unauthorized access_forbidden])
  end

  private
    def complete_window(monobank_account, window, by_id, seen_ids, now)
      monobank_account.history_synced_from = [ monobank_account.history_synced_from, window.from ].compact.min

      if window.kind.in?(%i[first forward])
        monobank_account.balance_at_forward_fetch = monobank_account.raw_balance_minor
        monobank_account.forward_fetched_at = now
        # A hold the statement no longer shows settled (maybe under a new id) or was cancelled
        by_id.reject! { |id, row| hold?(row) && (time = row_time(row)) && time >= window.from && !seen_ids.include?(id) }
      end

      monobank_account.page_from = nil
      monobank_account.page_to = nil
      monobank_account.page_kind = nil
      monobank_account.page_seen_ids = []

      target = MonobankItem::FetchPlan.target_start_for(monobank_account, now: now)
      monobank_account.history_complete = true if monobank_account.history_synced_from <= target
    end

    # The end of the next page when this response may be cut, else nil
    def next_page_to(monobank_account, window, rows)
      return nil if rows.size < Provider::Monobank::MAX_STATEMENT_ITEMS

      oldest = rows.filter_map { |row| row_time(row) }.min
      return nil if oldest.nil?

      oldest -= 1.second if monobank_account.page_to.present? && oldest >= monobank_account.page_to
      oldest > window.from ? oldest : nil
    end

    def row_key(row)
      MonobankEntry::Processor.canonical_external_id(row)
    end

    def hold?(row)
      MonobankEntry::Processor.pending?(row)
    end

    def row_time(row)
      MonobankItem::FetchPlan.row_time(row)
    end
end
