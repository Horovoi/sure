class Account::OpeningBalanceManager
  Result = Struct.new(:success?, :changes_made?, :error, keyword_init: true)

  def initialize(account)
    @account = account
  end

  def has_opening_anchor?
    opening_anchor_valuation.present?
  end

  # Most accounts should have an opening anchor. If not, we derive the opening date from the oldest entry date
  def opening_date
    return opening_anchor_valuation.entry.date if opening_anchor_valuation.present?

    [
      account.entries.valuations.order(:date).first&.date,
      account.entries.where.not(entryable_type: "Valuation").order(:date).first&.date&.prev_day
    ].compact.min || Date.current
  end

  def opening_balance
    opening_anchor_valuation&.entry&.amount || 0
  end

  # Serialized per account (see with_account_lock), so two concurrent calls cannot both create an anchor
  def set_opening_balance(balance:, date: nil)
    with_account_lock { set_opening_balance_unlocked(balance: balance, date: date) }
  end

  def set_opening_balance_unlocked(balance:, date: nil)
    resolved_date = date || default_date

    # Validate date is before oldest entry
    if (error = date_error(date))
      return Result.new(success?: false, changes_made?: false, error: error)
    end

    if opening_anchor_valuation.nil?
      create_opening_anchor(
        balance: balance,
        date: resolved_date
      )
      Result.new(success?: true, changes_made?: true, error: nil)
    else
      changes_made = update_opening_anchor(balance: balance, date: date)
      Result.new(success?: true, changes_made?: changes_made, error: nil)
    end
  end

  # Balances are calculated forward from the opening anchor, so an entry dated on or
  # before it would never count. Move the anchor to the day before the oldest entry,
  # keeping its amount: every entry then counts, and today's balance includes it.
  # Returns true when the anchor moved.
  def move_before_oldest_entry!
    return false unless opening_anchor_valuation

    anchor_entry = opening_anchor_valuation.entry
    oldest = account.entries.where.not(id: anchor_entry.id).minimum(:date)
    return false unless oldest && oldest <= anchor_entry.date

    anchor_entry.update!(date: oldest - 1.day)
    @oldest_entry_date = nil
    true
  rescue ActiveRecord::RecordInvalid => e
    # Only when the oldest entry sits at the earliest supported date
    Rails.logger.warn("Opening anchor for account #{account.id} not moved: #{e.message}")
    false
  end

  # The check set_opening_balance makes on an explicit date, without writing: an error message, or nil
  def date_error(date)
    return unless date && oldest_entry_date && date >= oldest_entry_date

    "Opening balance date must be before the oldest entry date"
  end

  private
    attr_reader :account

    # An assistant retrying set_opening_balance after a timeout can run two calls for one account at once; both
    # would see "no anchor" and create two. A row lock on the account serializes them, and the anchor is read
    # again under it, uncached, so a query cache filled before the other call committed cannot hide its anchor.
    # A plain row lock rather than with_lock: callers such as Account.create_and_sync may hold unsaved changes on
    # the account, which with_lock would reload.
    def with_account_lock
      Account.uncached do
        Account.transaction do
          Account.where(id: account.id).lock.pick(:id)
          @opening_anchor_valuation = nil
          @oldest_entry_date = nil

          yield
        end
      end
    end

    def opening_anchor_valuation
      @opening_anchor_valuation ||= account.valuations.opening_anchor.includes(:entry).order("entries.date ASC, entries.created_at ASC").first
    end

    # The opening anchor itself does not count: it may move to any date before the other entries
    def oldest_entry_date
      @oldest_entry_date ||= begin
        entries = account.entries
        entries = entries.where.not(id: opening_anchor_valuation.entry.id) if opening_anchor_valuation&.entry
        entries.minimum(:date)
      end
    end

    def default_date
      if oldest_entry_date
        [ oldest_entry_date - 1.day, 2.years.ago.to_date ].min
      else
        2.years.ago.to_date
      end
    end

    def create_opening_anchor(balance:, date:)
      account.entries.create!(
        date: date,
        name: Valuation.build_opening_anchor_name(account.accountable_type),
        amount: balance,
        currency: account.currency,
        entryable: Valuation.new(
          kind: "opening_anchor"
        )
      )
    end

    def update_opening_anchor(balance:, date: nil)
      changes_made = false

      ActiveRecord::Base.transaction do
        # Update associated entry attributes
        entry = opening_anchor_valuation.entry

        if entry.amount != balance
          entry.amount = balance
          changes_made = true
        end

        if date.present? && entry.date != date
          entry.date = date
          changes_made = true
        end

        entry.save! if entry.changed?
      end

      changes_made
    end

    # The set_opening_balance tool reports these
    public :oldest_entry_date, :default_date
    private :set_opening_balance_unlocked
end
