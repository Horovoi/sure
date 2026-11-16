# Split transactions: one transaction entry (the parent) divided into child entries,
# each with its own amount, name, category, merchant, tags, notes and excluded flag.
#
# The model, and the one rule every query follows:
#
# * The parent stays what the bank (or the user) recorded. It keeps its amount, date,
#   account, external id and provider data, and it alone moves the account balance.
#   Balances, provider claims, import duplicate checks, subscription reconciliation and
#   recurring-pattern detection read the parent and never a child
#   (Entry.excluding_split_children).
# * The children say what the money was for. Every spending and income figure (income
#   statement, budgets, reports, exports, the assistant's totals) reads the children and
#   never the parent: the parent is marked excluded while it is split, and those queries
#   already leave excluded entries out. Lists that show transactions one by one use
#   Entry.excluding_split_parents and show the parent as the header of its group.
# * The children sum exactly to the parent and share its account, currency and date.
#   Only #split!, #resplit! and #unsplit! change a child's amount or delete a child;
#   a change to the parent's date moves the children with it. A split parent's amount,
#   currency and account stay as they are until it is unsplit.
# * The children belong to their parent alone: no external id, source or import. A
#   provider, an import (and its revert) or a deletion acts on the parent, and the
#   children go with it.
# * Only a plain transaction splits: a standard or one-time transaction, posted, not
#   excluded, not a transfer leg or transfer fee, not a generated subscription charge,
#   not flagged as a possible duplicate. Transfer refuses a split parent or child as a
#   leg (Transfer#legs_not_split).
module Entry::Splittable
  extend ActiveSupport::Concern

  MAX_PARTS = 20
  SPLITTABLE_KINDS = %w[standard one_time].freeze

  # Why an entry cannot be split, for the drawer and the API-like callers
  class NotSplittable < StandardError; end

  included do
    # Set by #split!, #resplit! and #unsplit! while they write children, so the
    # validations below let those writes through and nothing else.
    attr_accessor :split_writing

    belongs_to :parent_entry, class_name: "Entry", optional: true, inverse_of: :child_entries
    has_many :child_entries, -> { order(:created_at, :id) }, class_name: "Entry", foreign_key: :parent_entry_id,
      inverse_of: :parent_entry, dependent: :destroy

    # The rows that move balances and that bank-level matching reads: no split child
    scope :excluding_split_children, -> { where(entries: { parent_entry_id: nil }) }

    # The rows a list of transactions shows one by one: no split parent (its children
    # stand in for it). NOT EXISTS on the partial index of parent_entry_id.
    scope :excluding_split_parents, -> { where(Entry.split_parent_sql("entries", negate: true)) }

    scope :split_parents, -> { where(Entry.split_parent_sql("entries")) }

    validate :split_child_unchanged, if: :split_child?
    validate :split_parent_unchanged

    before_destroy :keep_split_child, if: :split_child?, prepend: true
    after_update :move_split_children, if: :saved_change_to_date?
  end

  class_methods do
    # SQL that is true when the entry aliased `table` has split children
    def split_parent_sql(table = "entries", negate: false)
      "#{negate ? "NOT " : ""}EXISTS (SELECT 1 FROM entries split_children WHERE split_children.parent_entry_id = #{table}.id)"
    end

    # Ids among entry_ids that are split parents, as a Set, in one query
    def split_parent_ids_among(entry_ids)
      ids = Array(entry_ids).compact
      return Set.new if ids.empty?

      Entry.where(parent_entry_id: ids).distinct.pluck(:parent_entry_id).to_set
    end
  end

  def split_child?
    parent_entry_id.present?
  end

  def split_parent?
    return false if new_record?
    return child_entries.any? if association(:child_entries).loaded?

    child_entries.exists?
  end

  # Whether this entry can be split now. #split_blocker says why not.
  def splittable?
    split_blocker.nil?
  end

  # The reason this entry cannot be split (a symbol with a message under
  # activerecord.errors.models.entry_split_blockers), or nil when it can
  def split_blocker
    return :not_transaction unless transaction? && persisted?
    return :already_split if split_parent?
    return :split_child if split_child?
    return :excluded if excluded?
    return :zero_amount if amount.to_d.zero?

    txn = entryable
    return :transfer if txn.transfer? || txn.transfer.present? || txn.fee_transfer_id.present?
    return :kind unless txn.kind.in?(SPLITTABLE_KINDS)
    return :pending if txn.pending?
    return :generated_charge if source == "subscription"
    return :possible_duplicate if txn.has_potential_duplicate?

    nil
  end

  # Divides this entry into children. parts: an array of hashes with :name, :amount (signed
  # like Entry#amount), and optional :category_id, :merchant_id, :tag_ids, :notes, :excluded.
  # Raises ActiveRecord::RecordInvalid when the parts are wrong, NotSplittable when the
  # entry cannot be split (checked again under the lock, so two submits cannot both split).
  # Returns the children.
  def split!(parts)
    with_split_lock do
      blocker = split_blocker
      raise NotSplittable, split_error_message(blocker) if blocker

      parts = normalize_split_parts(parts)
      validate_split_parts!(parts)

      children = parts.map { |part| create_split_child!(part) }

      # Excluded is enough to keep a provider sync off the parent while it is split
      # (Entry#protected_from_sync?); user_modified is left as it was, so an unsplit
      # gives back the entry as the bank sent it
      self.split_writing = true
      update!(excluded: true)
      children
    ensure
      self.split_writing = false
    end
  end

  # Changes the parts of a split. A part with the id of an existing child updates that
  # child in place (keeping what the editor does not show: attachments, locks, provider
  # data); a part without one adds a child; a child no part names is deleted.
  def resplit!(parts)
    with_split_lock do
      raise NotSplittable, split_error_message(:not_split) unless split_parent?

      parts = normalize_split_parts(parts)
      validate_split_parts!(parts)

      existing = child_entries.includes(:entryable).index_by(&:id)
      kept_ids = parts.filter_map { |part| part[:id] if existing.key?(part[:id]) }

      existing.except(*kept_ids).each_value { |child| destroy_split_child!(child) }

      children = parts.map do |part|
        child = existing[part[:id]]
        child ? update_split_child!(child, part) : create_split_child!(part)
      end

      child_entries.reset
      children
    end
  end

  # Deletes the children and gives the parent back its own place in every figure
  def unsplit!
    with_split_lock do
      raise NotSplittable, split_error_message(:not_split) unless split_parent?

      child_entries.includes(:entryable).each { |child| destroy_split_child!(child) }
      child_entries.reset

      self.split_writing = true
      update!(excluded: false)
      true
    ensure
      self.split_writing = false
    end
  end

  # The decimals a part may have: the currency's, or the transaction's own when it has
  # more (a converted amount; at most the 4 entries.amount keeps). The split editor
  # takes the same.
  def split_precision
    decimals = amount.abs.to_s("F").split(".").last.to_s.sub(/0+\z/, "").length
    [ Money::Currency.new(currency).default_precision, decimals ].max.clamp(0, 4)
  end

  # The children's total, signed like Entry#amount
  def split_total
    child_entries.sum(&:amount)
  end

  private
    # Locks this entry's row (and reloads it) for the length of one database
    # transaction. Entry#transaction is the delegated_type accessor of the Transaction
    # entryable, so the class method opens the database transaction.
    def with_split_lock
      self.class.transaction do
        lock!
        yield
      end
    end

    def split_error_message(reason)
      I18n.t("activerecord.errors.models.entry_split_blockers.#{reason}")
    end

    # Each part as a hash with :id, :name and :amount, plus only the optional keys the
    # caller gave (:category_id, :merchant_id, :tag_ids, :notes, :excluded): a key left
    # out keeps the child's value on an edit and takes the default on a new child.
    # An id given twice names its child once; the second part is a new child.
    def normalize_split_parts(parts)
      seen_ids = Set.new

      Array(parts).map do |part|
        part = part.to_h.symbolize_keys
        id = part[:id].presence
        id = nil unless id.nil? || seen_ids.add?(id)
        normalized = {
          id: id,
          name: part[:name].to_s.strip.presence || name,
          amount: part[:amount].to_s.strip.presence && BigDecimal(part[:amount].to_s.strip)
        }
        normalized[:category_id] = part[:category_id].presence if part.key?(:category_id)
        normalized[:merchant_id] = part[:merchant_id].presence if part.key?(:merchant_id)
        normalized[:tag_ids] = Array(part[:tag_ids]).compact_blank if part.key?(:tag_ids)
        normalized[:notes] = part[:notes].to_s.strip.presence if part.key?(:notes)
        normalized[:excluded] = ActiveModel::Type::Boolean.new.cast(part[:excluded]) || false if part.key?(:excluded)
        normalized
      end
    rescue ArgumentError, TypeError
      split_failure!(:invalid_amount)
    end

    def validate_split_parts!(parts)
      split_failure!(:too_few_parts) if parts.size < 2
      split_failure!(:too_many_parts) if parts.size > MAX_PARTS
      split_failure!(:invalid_amount) if parts.any? { |part| part[:amount].nil? || part[:amount].zero? }
      # A part has no more decimals than the currency, or than the transaction itself
      # when it has more (a converted amount): finer parts would show as 0.00
      precision = split_precision
      if parts.any? { |part| part[:amount].round(precision) != part[:amount] }
        split_failure!(:too_many_decimals, count: precision)
      end
      # Every part is at least one minor unit of the currency (0.01 ₴)
      minimum = BigDecimal(1) / 10**Money::Currency.new(currency).default_precision
      if parts.any? { |part| part[:amount].abs < minimum }
        split_failure!(:part_below_minimum, minimum: Money.new(minimum, currency).format)
      end

      total = parts.sum { |part| part[:amount] }
      return if total == amount

      split_failure!(:sum_mismatch, expected: amount_money.format, actual: Money.new(total, currency).format)
    end

    def split_failure!(reason, **options)
      errors.add(:base, :"split_#{reason}", **options)
      raise ActiveRecord::RecordInvalid, self
    end

    def create_split_child!(part)
      txn = Transaction.new(
        kind: entryable.kind == "one_time" ? "one_time" : "standard",
        investment_activity_label: entryable.investment_activity_label,
        category_id: part[:category_id],
        merchant_id: part.key?(:merchant_id) ? part[:merchant_id] : entryable.merchant_id,
        tag_ids: part[:tag_ids] || []
      )

      child = child_entries.build(
        account: account,
        date: date,
        currency: currency,
        name: part[:name],
        amount: part[:amount],
        notes: part[:notes],
        excluded: part.fetch(:excluded, false),
        user_modified: true,
        entryable: txn,
        created_at: next_split_child_time
      )
      child.split_writing = true
      child.save!
      # What the user picked is kept from rules and auto-categorization, as for a
      # transaction entered by hand
      child.lock_saved_attributes!
      child.transaction.lock_attr!(:tag_ids) if child.transaction.tag_ids.any?
      child
    ensure
      child&.split_writing = false
    end

    # Parts are listed by created_at, in the order the editor gave them. Each new part gets
    # a time after the latest part, so that order holds even when the clock does not move
    # between two inserts (a frozen test clock, or a coarse system clock).
    def next_split_child_time
      now = Time.current
      latest = Entry.where(parent_entry_id: id).maximum(:created_at)
      latest && latest >= now ? latest + Rational(1, 1_000_000) : now
    end

    def update_split_child!(child, part)
      child.split_writing = true
      child.assign_attributes(part.slice(:name, :amount, :notes, :excluded))
      txn = child.transaction
      txn.assign_attributes(part.slice(:category_id, :merchant_id))
      child.save!
      txn.save! if txn.changed?
      txn.update!(tag_ids: part[:tag_ids]) if part.key?(:tag_ids) && txn.tag_ids.sort != part[:tag_ids].sort
      child.lock_saved_attributes!
      child
    ensure
      child.split_writing = false
    end

    def destroy_split_child!(child)
      child.split_writing = true
      child.destroy!
    end

    # A child's amount, date, account and currency follow the split; its parent never changes
    def split_child_unchanged
      return if new_record? || split_writing

      changed = %w[amount currency account_id parent_entry_id date] & changed_attribute_names_to_save
      errors.add(:base, :split_child_locked) if changed.any?
    end

    # A split parent keeps its amount, currency and account, and stays out of the figures,
    # until it is unsplit
    def split_parent_unchanged
      return if new_record? || split_writing
      return unless will_save_change_to_amount? || will_save_change_to_currency? ||
        will_save_change_to_account_id? || will_save_change_to_excluded?
      return unless split_parent?

      errors.add(:base, :split_parent_locked)
    end

    def keep_split_child
      return if destroyed_by_association || split_writing

      errors.add(:base, :split_child_not_deletable)
      throw :abort
    end

    # The children are dated like their parent
    def move_split_children
      return if split_child?

      Entry.where(parent_entry_id: id).update_all(date: date, updated_at: Time.current)
    end
end
