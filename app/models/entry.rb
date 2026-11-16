class Entry < ApplicationRecord
  include Monetizable, Enrichable, Splittable

  # Attributes that only describe an entry. Balance materialization and transfer
  # matching never read them, so an edit limited to them needs no account sync.
  # Reports and budgets pick such an edit up through Family#entries_cache_version:
  # the save bumps the entry's updated_at (a transaction's save touches its entry).
  DESCRIPTIVE_ATTRIBUTES = %w[name notes updated_at].freeze
  DESCRIPTIVE_TRANSACTION_ATTRIBUTES = %w[category_id merchant_id updated_at].freeze

  monetize :amount

  belongs_to :account
  belongs_to :import, optional: true

  # inverse_of: an entryable preloaded with `includes(:entryable)` knows its entry, so
  # entryable.entry (Transfer legs, category checks) runs no query per row
  delegated_type :entryable, types: Entryable::TYPES, dependent: :destroy, inverse_of: :entry
  accepts_nested_attributes_for :entryable

  # --- Reconciliation status (w3-toolstrx reconciliation-status) ---
  # The user's own mark for checking a transaction off against a bank statement:
  # unreconciled (not checked yet), cleared (seen on a statement) and reconciled (the
  # statement period is done). It is not the provider's pending flag. Only transactions
  # of manual accounts show it or take it. The attribute is declared so the enum boots
  # before the column's migration has run.
  attribute :reconciled_status, :string, default: "unreconciled"
  enum :reconciled_status, {
    unreconciled: "unreconciled",
    cleared: "cleared",
    reconciled: "reconciled"
  }, default: "unreconciled", validate: true

  # The order a click on the status badge moves through, back to the start after the last
  RECONCILED_STATUS_CYCLE = reconciled_statuses.keys.freeze

  scope :needs_reconciliation, -> { where(reconciled_status: %w[unreconciled cleared]) }
  # --- end reconciliation status ---

  validates :date, :name, :amount, :currency, presence: true
  validates :date, uniqueness: { scope: [ :account_id, :entryable_type ] }, if: -> { valuation? }
  validates :date, comparison: { greater_than: -> { min_supported_date } }
  validates :external_id, uniqueness: { scope: [ :account_id, :source ] }, if: -> { external_id.present? && source.present? }
  validate :one_anchor_per_kind, if: :valuation?

  # The opening anchor is where the balance history starts (and a linked account's current
  # anchor is where it ends). Deleting one on its own silently changes every balance, so it is
  # only removed together with its account (or import).
  before_destroy :ensure_anchor_destroyable, prepend: true

  scope :visible, -> {
    joins(:account).merge(Account.visible)
  }

  scope :chronological, -> {
    order(
      date: :asc,
      Arel.sql("CASE WHEN entries.entryable_type = 'Valuation' THEN 1 ELSE 0 END") => :asc,
      created_at: :asc,
      id: :asc # tie-break, so paging never skips or repeats entries created in the same instant
    )
  }

  scope :reverse_chronological, -> {
    order(
      date: :desc,
      Arel.sql("CASE WHEN entries.entryable_type = 'Valuation' THEN 1 ELSE 0 END") => :desc,
      created_at: :desc,
      id: :desc # tie-break, so paging never skips or repeats entries created in the same instant
    )
  }

  # Pending transaction scopes - check Transaction.extra for provider pending flags
  # Works with any provider that stores pending status in extra["provider_name"]["pending"]
  scope :pending, -> {
    joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(<<~SQL.squish)
        EXISTS (
          SELECT 1 FROM jsonb_each(transactions.extra) AS pd
          WHERE (pd.value ->> 'pending')::boolean = true
        )
      SQL
  }

  # A provider's pending holds: transaction entries written by source (the provider key,
  # e.g. "monobank") whose extra[source]["pending"] is true
  scope :pending_from, ->(source) {
    joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(source: source.to_s)
      .where(Transaction.pending_sql("transactions", provider: source))
  }

  # Leaves out released provider holds (as Transaction.released_hold_sql); other entries stay
  scope :excluding_released_holds, -> {
    where(<<~SQL.squish)
      entries.entryable_type != 'Transaction'
      OR NOT EXISTS (
        SELECT 1 FROM transactions t, jsonb_each(t.extra) AS rh
        WHERE t.id = entries.entryable_id
        AND jsonb_typeof(rh.value) = 'object'
        AND (rh.value ->> 'hold_released_at') IS NOT NULL
      )
    SQL
  }

  scope :excluding_pending, -> {
    # For non-Transaction entries (Trade, Valuation), always include
    # For Transaction entries, exclude if pending flag is true
    where(<<~SQL.squish)
      entries.entryable_type != 'Transaction'
      OR NOT EXISTS (
        SELECT 1 FROM transactions t
        WHERE t.id = entries.entryable_id
        AND EXISTS (
          SELECT 1 FROM jsonb_each(t.extra) AS pd
          WHERE (pd.value ->> 'pending')::boolean = true
        )
      )
    SQL
  }

  # Transactions with no category that the user can still categorize: on a visible account,
  # not excluded, and not a leg of a transfer between own accounts. The categorize wizard and
  # its count on the transactions page read this scope.
  # The account test is a subquery, not a join: Family#entries joins accounts already.
  scope :uncategorized_transactions, -> {
    joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(account_id: Account.visible.select(:id))
      .where(transactions: { category_id: nil })
      .where.not(transactions: { kind: Transaction::UNCATEGORIZED_EXCLUDED_KINDS })
      .where(entries: { excluded: false })
  }

  # Uncategorized transactions whose name contains `filter` (spaces collapsed, case ignored),
  # of the given type ("income" or "expense"). It is the same match as the "name contains"
  # rule the categorize wizard offers, so the preview shows what that rule would catch now.
  def self.uncategorized_matching(entries, filter, transaction_type = nil)
    normalized = filter.to_s.gsub(/[[:space:]]+/, " ").strip
    return none if normalized.empty?

    scope = entries
      .uncategorized_transactions
      .where("BTRIM(REGEXP_REPLACE(entries.name, '[[:space:]]+', ' ', 'g')) ILIKE ?", "%#{sanitize_sql_like(normalized)}%")

    scope = case transaction_type
    when "income" then scope.where(Transaction::Grouper::INCOME_SQL)
    when "expense" then scope.where.not(Transaction::Grouper::INCOME_SQL)
    else scope
    end

    scope.includes(:account, entryable: :merchant).order(date: :desc, id: :desc)
  end

  def classification
    amount.negative? ? "income" : "expense"
  end

  def lock_saved_attributes!
    super
    entryable.lock_saved_attributes!
  end

  def sync_account_later
    sync_start_date = [ date_previously_was, date ].compact.min unless destroyed?
    account.sync_later(window_start_date: sync_start_date)
  end

  # Whether the last save changed anything a sync depends on. Call it right after
  # the save, before a follow-up write (lock_saved_attributes!, mark_user_modified!)
  # resets saved_changes.
  def saved_changes_affect_balances?
    return true if (saved_changes.keys - DESCRIPTIVE_ATTRIBUTES).any?

    descriptive = transaction? ? DESCRIPTIVE_TRANSACTION_ATTRIBUTES : %w[updated_at]
    (entryable.saved_changes.keys - descriptive).any?
  end

  # Whether the last save changed what recurring-pattern detection groups by. A sync
  # runs the detection when it finishes; an edit that skips the sync asks for it here.
  def saved_changes_affect_recurring_patterns?
    return true if saved_change_to_name?

    transaction? && (entryable.saved_change_to_category_id? || entryable.saved_change_to_merchant_id?)
  end

  def entryable_name_short
    entryable_type.demodulize.underscore
  end

  # Sources of entries made by hand that still carry an external_id: create_transaction stores its idempotency
  # key there. They stay editable like any manual entry.
  MANUAL_SOURCES = %w[mcp].freeze

  def linked?
    external_id.present? && !source.in?(MANUAL_SOURCES)
  end

  # Checks if entry should be protected from provider sync overwrites.
  # This does NOT prevent user from editing - only protects from automated sync.
  #
  # @return [Boolean] true if entry should be skipped during provider sync
  def protected_from_sync?
    excluded? || user_modified? || import_locked?
  end

  # Marks entry as user-modified after manual edit.
  # Called when user edits any field to prevent provider sync from overwriting.
  #
  # @return [Boolean] true if successfully marked
  def mark_user_modified!
    return true if user_modified?
    update!(user_modified: true)
  end

  # Whether the reconciliation mark applies: a transaction of a manual account. A part of
  # a split is checked off through its parent, the line the statement shows.
  def reconcilable?
    transaction? && account.manual? && !split_child?
  end

  # Moves the reconciliation mark one step along RECONCILED_STATUS_CYCLE. A check
  # against a statement is not an edit, so nothing is locked or marked user-modified.
  def advance_reconciled_status!
    index = RECONCILED_STATUS_CYCLE.index(reconciled_status) || 0
    update!(reconciled_status: RECONCILED_STATUS_CYCLE[(index + 1) % RECONCILED_STATUS_CYCLE.size])
  end

  class << self
    def search(params)
      EntrySearch.new(params).build_query(all)
    end

    # arbitrary cutoff date to avoid expensive sync operations
    def min_supported_date
      30.years.ago.to_date
    end

    def bulk_update!(bulk_update_params, update_tags: false)
      bulk_attributes = {
        date: bulk_update_params[:date],
        notes: bulk_update_params[:notes],
        # A blank name leaves each name as it is; a new one is a user edit and gets locked below
        name: bulk_update_params[:name].to_s.strip,
        entryable_attributes: {
          category_id: bulk_update_params[:category_id],
          merchant_id: bulk_update_params[:merchant_id]
        }.compact_blank
      }.compact_blank

      tag_ids = Array.wrap(bulk_update_params[:tag_ids]).reject(&:blank?)
      reconciled_status = bulk_update_params[:reconciled_status].presence
      has_updates = bulk_attributes.present? || update_tags || reconciled_status.present?

      return 0 unless has_updates

      if reconciled_status && !reconciled_statuses.key?(reconciled_status)
        raise ArgumentError, "unknown reconciled_status #{reconciled_status.inspect}"
      end

      updated_count = 0
      # One query for the selection's manual accounts, not one per entry
      manual_account_ids = reconciled_status ? Account.manual.where(id: select(:account_id)).pluck(:id).to_set : Set.new

      # A date change moves the entry in the balance history, so its account must
      # resync from the earlier of the two dates, as a single update does.
      sync_windows = {}
      recurring_account_ids = Set.new

      transaction do
        all.each do |entry|
          attrs = bulk_attributes_for(entry, bulk_attributes)
          update_entry_tags = update_tags && entry.transaction?
          # Only transactions of manual accounts take the reconciliation mark; the rest skip it
          reconcile = reconciled_status.present? && entry.transaction? && !entry.split_child? &&
            manual_account_ids.include?(entry.account_id) && entry.reconciled_status != reconciled_status
          next if attrs.blank? && !update_entry_tags && !reconcile

          updated_count += 1

          if attrs.present?
            entry.update! attrs

            # A category or merchant change skips the sync, which is what runs the
            # recurring-pattern detection; ask for it once per family instead.
            recurring_account_ids << entry.account_id if entry.saved_changes_affect_recurring_patterns?
            # Bulk edit is a manual pick, so it counts toward the pickers' "Recent" group.
            entry.transaction.record_category_usage! if entry.transaction?

            if entry.saved_change_to_date?
              start_date = [ entry.date_previously_was, entry.date ].compact.min
              account, earliest = sync_windows[entry.account_id]
              sync_windows[entry.account_id] = [ account || entry.account, [ earliest, start_date ].compact.min ]
            end
          end

          if update_entry_tags
            entry.transaction.tag_ids = tag_ids
            entry.transaction.save!
            entry.entryable.lock_attr!(:tag_ids) if entry.transaction.tags.any?
          end

          # A reconcile-only change is a check, not an edit: nothing to lock
          if attrs.present? || update_entry_tags
            entry.lock_saved_attributes!
            entry.mark_user_modified!
          end

          # After the lock, so the mark itself is never a locked attribute
          entry.update!(reconciled_status: reconciled_status) if reconcile
        end
      end

      sync_windows.each_value do |account, start_date|
        account.sync_later(window_start_date: start_date)
      end

      # Debounced, so one call per family; a date-change sync above runs it again when it finishes
      if recurring_account_ids.any?
        Family.where(id: Account.where(id: recurring_account_ids.to_a).select(:family_id)).find_each do |family|
          RecurringTransaction.identify_patterns_for(family)
        end
      end

      # The entries that changed: a skipped one (a valuation given only a category, an
      # entry already at the asked status) is not counted
      updated_count
    end

    private
      # Category and merchant belong to a transaction: a valuation or trade in the
      # selection gets only the entry fields. Each entry gets its own copy with its
      # own entryable id.
      def bulk_attributes_for(entry, bulk_attributes)
        attrs = bulk_attributes.deep_dup
        # A part of a split keeps its parent's date (Entry::Splittable)
        attrs.delete(:date) if entry.split_child?

        if entry.transaction? && attrs[:entryable_attributes].present?
          attrs[:entryable_attributes][:id] = entry.entryable_id
        else
          attrs.delete(:entryable_attributes)
        end

        attrs
      end
  end

  private
    def protected_anchor?
      return false unless valuation? && entryable

      entryable.opening_anchor? || (entryable.current_anchor? && account&.linked?)
    end

    def ensure_anchor_destroyable
      return if destroyed_by_association
      return unless protected_anchor?

      errors.add(:base, :anchor_not_deletable)
      throw :abort
    end

    def one_anchor_per_kind
      return unless entryable && (entryable.opening_anchor? || entryable.current_anchor?)
      return unless new_record? || entryable.kind_changed?

      others = Entry.where(account_id: account_id, entryable_type: "Valuation")
        .where(entryable_id: Valuation.where(kind: entryable.kind).select(:id))
      others = others.where.not(id: id) if persisted?

      errors.add(:base, :duplicate_anchor) if others.exists?
    end
end
