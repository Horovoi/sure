class Entry < ApplicationRecord
  include Monetizable, Enrichable

  monetize :amount

  belongs_to :account
  belongs_to :import, optional: true

  delegated_type :entryable, types: Entryable::TYPES, dependent: :destroy
  accepts_nested_attributes_for :entryable

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
      created_at: :asc
    )
  }

  scope :reverse_chronological, -> {
    order(
      date: :desc,
      Arel.sql("CASE WHEN entries.entryable_type = 'Valuation' THEN 1 ELSE 0 END") => :desc,
      created_at: :desc
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

  def entryable_name_short
    entryable_type.demodulize.underscore
  end

  def linked?
    external_id.present?
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
        entryable_attributes: {
          category_id: bulk_update_params[:category_id],
          merchant_id: bulk_update_params[:merchant_id]
        }.compact_blank
      }.compact_blank

      tag_ids = Array.wrap(bulk_update_params[:tag_ids]).reject(&:blank?)
      has_updates = bulk_attributes.present? || update_tags

      return 0 unless has_updates

      # A date change moves the entry in the balance history, so its account must
      # resync from the earlier of the two dates, as a single update does.
      sync_windows = {}

      transaction do
        all.each do |entry|
          if bulk_attributes.present?
            bulk_attributes[:entryable_attributes][:id] = entry.entryable_id if bulk_attributes[:entryable_attributes].present?
            entry.update! bulk_attributes

            if entry.saved_change_to_date?
              start_date = [ entry.date_previously_was, entry.date ].compact.min
              account, earliest = sync_windows[entry.account_id]
              sync_windows[entry.account_id] = [ account || entry.account, [ earliest, start_date ].compact.min ]
            end
          end

          if update_tags && entry.transaction?
            entry.transaction.tag_ids = tag_ids
            entry.transaction.save!
            entry.entryable.lock_attr!(:tag_ids) if entry.transaction.tags.any?
          end

          entry.lock_saved_attributes!
          entry.mark_user_modified!
        end
      end

      sync_windows.each_value do |account, start_date|
        account.sync_later(window_start_date: start_date)
      end

      all.size
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
