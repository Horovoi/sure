# Turns a product's stored statement rows into entries.
#
#   claims   new settled rows first try to take over a hand-entered entry of the
#            account (Account::ProviderEntryClaimer: same amount, same day or within
#            3 days), in one batch so each entry is claimed at most once
#   cut-over rows dated before the account's cut-over that claimed nothing are skipped
#   holds    pending entries whose hold is no longer stored are removed, or kept and
#            released when the user worked on them (Account::ProviderPendingPruner)
#   MCC      a category from the MCC is set only on uncategorised entries, when the
#            connection allows it; own transfers never get one
#
# After a pass without failures, settled rows older than MonobankAccount::RAW_RETENTION
# are dropped from the stored rows: their entries exist and the external id makes a
# later import of the same row idempotent.
class MonobankAccount::Transactions::Processor
  SOURCE = MonobankEntry::Processor::SOURCE

  attr_reader :monobank_account, :import_adapter

  def initialize(monobank_account, import_adapter: nil, category_matcher: :auto, now: Time.current)
    @monobank_account = monobank_account
    @import_adapter = import_adapter
    @category_matcher = category_matcher
    @now = now
  end

  def process
    return empty_result if account.nil?

    rows = Array(monobank_account.raw_transactions_payload).select { |row| row.is_a?(Hash) }
    processors = rows.map { |row| build_processor(row) }
    claims = claim_matches(processors)

    imported = 0
    failed_ids = Set.new
    errors = []

    processors.each do |processor|
      entry = build_processor(processor.row, claimed_entry: claims[processor.external_id], category: category_for(processor)).process
      imported += 1 if entry
    rescue => e
      failed_ids << processor.external_id
      errors << { external_id: processor.external_id, error: "#{e.class}: #{e.message}" }
      Rails.logger.error("MonobankAccount::Transactions::Processor - row #{processor.external_id} failed: #{e.class} - #{e.message}")
    end

    prune = pruner.prune!(keep_external_ids: processors.select(&:pending?).map(&:external_id))
    trim_rows!(rows, failed_ids) if errors.empty?

    skipped = adapter.skipped_entries
    {
      success: errors.empty?,
      total: rows.size,
      imported: imported,
      failed: errors.size,
      claimed: adapter.claimed_entries.size,
      skipped_before_cutover: skipped.count { |s| s[:reason] == "before_cutover" },
      skipped: skipped.size,
      pruned: prune[:pruned].to_i,
      detached: prune[:detached].to_i,
      errors: errors.first(20)
    }
  end

  private
    attr_reader :now

    def account
      @account ||= monobank_account.current_account
    end

    def family
      account.family
    end

    def monobank_item
      monobank_account.monobank_item
    end

    def adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def pruner
      Account::ProviderPendingPruner.new(account, source: SOURCE)
    end

    def cutover_date
      return @cutover_date if defined?(@cutover_date)

      @cutover_date = account.respond_to?(:provider_cutover_date) ? account.provider_cutover_date : nil
    end

    def build_processor(row, claimed_entry: nil, category: nil)
      MonobankEntry::Processor.new(
        row,
        monobank_account: monobank_account,
        import_adapter: adapter,
        claimed_entry: claimed_entry,
        category_id_if_blank: category&.id,
        cutover_date: cutover_date
      )
    end

    # New settled rows (no entry with their id yet) matched against hand-entered entries
    def claim_matches(processors)
      existing = account.entries.where(source: SOURCE, external_id: processors.map(&:external_id)).pluck(:external_id).to_set
      candidates = processors.reject { |p| p.pending? || existing.include?(p.external_id) }
      return {} if candidates.empty?

      rows = candidates.filter_map do |processor|
        Account::ProviderEntryClaimer::Row.new(
          key: processor.external_id, date: processor.date, amount: processor.amount,
          currency: processor.currency, pending: false
        )
      rescue ArgumentError
        nil
      end

      Account::ProviderEntryClaimer.new(account, source: SOURCE).match(rows)
    end

    # --- MCC -------------------------------------------------------------------

    def category_matcher
      return @category_matcher unless @category_matcher == :auto
      return @category_matcher = nil unless monobank_item.apply_mcc_categories?

      @category_matcher = "Mcc::CategoryMatcher".safe_constantize&.new(family)
    end

    def category_for(processor)
      return nil if category_matcher.nil?

      category_matcher.category_for(
        mcc: processor.mcc,
        original_mcc: processor.original_mcc,
        amount: processor.amount,
        description: processor.description,
        own_transfer: own_transfer?(processor)
      )
    rescue ArgumentError
      nil
    end

    def own_transfer?(processor)
      return true if processor.counter_iban.present? && own_ibans.include?(processor.counter_iban)

      taxonomy = "Mcc::Taxonomy".safe_constantize
      taxonomy.respond_to?(:own_transfer?) && taxonomy.own_transfer?(description: processor.description)
    end

    def own_ibans
      @own_ibans ||= monobank_item.own_ibans
    end

    # --- Stored rows -----------------------------------------------------------

    def trim_rows!(rows, failed_ids)
      cutoff = now - MonobankAccount::RAW_RETENTION
      kept = rows.reject do |row|
        next false if MonobankEntry::Processor.pending?(row)
        next false if failed_ids.include?(MonobankEntry::Processor.canonical_external_id(row))

        time = MonobankItem::FetchPlan.row_time(row)
        time.present? && time < cutoff
      end
      return if kept.size == rows.size

      monobank_account.with_lock do
        # Rows a fetch stored meanwhile stay; only the trimmed ones go
        dropped = (rows - kept).map { |row| MonobankEntry::Processor.canonical_external_id(row) }.to_set
        current = Array(monobank_account.raw_transactions_payload)
        monobank_account.update!(raw_transactions_payload: current.reject { |row| dropped.include?(MonobankEntry::Processor.canonical_external_id(row)) })
      end
    end

    def empty_result
      { success: true, total: 0, imported: 0, failed: 0, claimed: 0, skipped_before_cutover: 0, skipped: 0, pruned: 0, detached: 0, errors: [] }
    end
end
