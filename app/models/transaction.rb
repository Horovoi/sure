class Transaction < ApplicationRecord
  include Entryable, Transferable, Ruleable

  belongs_to :category, optional: true
  belongs_to :merchant, optional: true
  belongs_to :recurring_transaction, optional: true
  # w2-transfers transfer-fees: set on the expense a transfer's fee is booked as
  belongs_to :fee_transfer, class_name: "Transfer", optional: true, inverse_of: :fee_transactions

  has_many :taggings, as: :taggable, dependent: :destroy
  has_many :tags, through: :taggings

  accepts_nested_attributes_for :taggings, allow_destroy: true

  # What a transaction row reads besides the transaction itself (see transactions/_transaction):
  # category, merchant (with its uploaded logo, which FamilyMerchant#logo_url reads), tags,
  # and for transfers both legs' accounts (the counterpart name, the pending pill, Transfer#categorizable?) plus, on an inflow row, the outflow's
  # category that the row shows read-only. Preload these when rendering a list, so rows do
  # not look them up one by one. The row's own leg is set by inverse_of; it is listed too
  # so a preload that skips the inverse still finds it loaded.
  ROW_ASSOCIATIONS = [
    :category, { merchant: { logo_attachment: :blob } }, :tags,
    {
      transfer_as_inflow: { inflow_transaction: { entry: :account }, outflow_transaction: [ :category, { entry: :account } ] },
      transfer_as_outflow: { inflow_transaction: { entry: :account }, outflow_transaction: { entry: :account } }
    }
  ].freeze

  after_save :clear_merchant_unlinked_association, if: :merchant_id_previously_changed?

  # w2-transfers custom-exchange-rate: a rate the user entered for a transaction in a
  # currency other than its account's (the bank's rate). Stored in extra["exchange_rate"]
  # as a decimal string; Balance::SyncCache converts the amount with it instead of the
  # stored market rate.
  validate :exchange_rate_must_be_positive

  enum :kind, {
    standard: "standard", # A regular transaction, included in budget analytics
    funds_movement: "funds_movement", # Movement of funds between accounts, excluded from budget analytics
    cc_payment: "cc_payment", # A CC payment, excluded from budget analytics (CC payments offset the sum of expense transactions)
    loan_payment: "loan_payment", # A payment to a Loan account, treated as an expense in budgets
    one_time: "one_time", # A one-time expense/income, excluded from budget analytics
    investment_contribution: "investment_contribution" # Transfer to investment/crypto account, excluded from budget analytics
  }

  # All valid investment activity labels (for UI dropdown)
  ACTIVITY_LABELS = [
    "Buy", "Sell", "Sweep In", "Sweep Out", "Dividend", "Reinvestment",
    "Interest", "Fee", "Transfer", "Contribution", "Withdrawal", "Exchange", "Other"
  ].freeze

  # Internal movement labels that should be excluded from budget (auto cash management)
  INTERNAL_MOVEMENT_LABELS = [ "Transfer", "Sweep In", "Sweep Out", "Exchange" ].freeze
  TRANSFER_KINDS = %w[funds_movement cc_payment loan_payment].freeze

  # Kinds the "Uncategorized" filter and the categorize wizard leave out: the two legs of a
  # transfer between own accounts have nothing to categorize. A loan payment and an
  # investment contribution are budget outflows, so they stay in.
  UNCATEGORIZED_EXCLUDED_KINDS = %w[funds_movement cc_payment].freeze

  # Kinds that budgets and the income statement leave out. loan_payment and
  # investment_contribution are not here: those transfers count as spending.
  BUDGET_EXCLUDED_KINDS = %w[funds_movement one_time cc_payment].freeze

  # BUDGET_EXCLUDED_KINDS as a quoted SQL list, for `kind NOT IN (...)` in raw queries.
  def self.budget_excluded_kinds_sql
    BUDGET_EXCLUDED_KINDS.map { |kind| connection.quote(kind) }.join(", ")
  end

  # Pending transaction scopes - filter based on provider pending flags in extra JSONB
  # Works with any provider that stores pending status in extra["provider_name"]["pending"]
  scope :pending, -> {
    where(<<~SQL.squish)
      EXISTS (
        SELECT 1 FROM jsonb_each(transactions.extra) AS pd
        WHERE (pd.value ->> 'pending')::boolean = true
      )
    SQL
  }

  scope :excluding_pending, -> {
    where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1 FROM jsonb_each(transactions.extra) AS pd
        WHERE (pd.value ->> 'pending')::boolean = true
      )
    SQL
  }

  scope :from_subscription, -> { where.not(recurring_transaction_id: nil) }

  # Arel conditions behind the income / expense / transfer filters, for a query that has
  # entries joined. Built as nodes, not SQL strings, so callers combine them with and/or/not.
  # A query without transactions joined passes its own tests for the two kinds.
  def self.type_conditions(transfer: arel_table[:kind].in(TRANSFER_KINDS), investment_contribution: arel_table[:kind].eq("investment_contribution"))
    amount = Entry.arel_table[:amount]

    {
      transfer: transfer,
      investment_contribution: investment_contribution,
      # An investment contribution is always an expense, whatever its sign (manual outflows
      # and provider-imported inflows such as 401k contributions alike)
      expense: amount.gteq(0).or(investment_contribution),
      income: amount.lteq(0).and(investment_contribution.not)
    }
  end

  # Overarching grouping method for all transfer-type transactions
  def transfer?
    kind.in?(TRANSFER_KINDS)
  end

  def set_category!(category)
    if category.is_a?(String)
      category = entry.account.family.categories.find_or_create_by_name!(category)
    end

    update!(category: category)
  end

  def pending?
    extra_data = extra.is_a?(Hash) ? extra : {}
    extra_data.values.any? do |provider_data|
      next false unless provider_data.is_a?(Hash)
      ActiveModel::Type::Boolean.new.cast(provider_data["pending"])
    end
  rescue
    false
  end

  # Potential duplicate matching methods
  # These help users review and resolve fuzzy-matched pending/posted pairs

  def has_potential_duplicate?
    potential_posted_match_data.present? && !potential_duplicate_dismissed?
  end

  def potential_duplicate_entry
    return nil unless has_potential_duplicate?
    Entry.find_by(id: potential_posted_match_data["entry_id"])
  end

  def potential_duplicate_reason
    potential_posted_match_data&.dig("reason")
  end

  def potential_duplicate_confidence
    potential_posted_match_data&.dig("confidence") || "medium"
  end

  def low_confidence_duplicate?
    potential_duplicate_confidence == "low"
  end

  def potential_duplicate_posted_amount
    potential_posted_match_data&.dig("posted_amount")&.to_d
  end

  def potential_duplicate_dismissed?
    potential_posted_match_data&.dig("dismissed") == true
  end

  # Records that posted_entry may be the same transaction as this one, for the
  # user to merge or dismiss. Keeps the first suggestion: an existing one, also
  # a dismissed one, is never replaced, so a dismissed pair is not flagged again.
  # Returns whether a suggestion was stored.
  def flag_potential_duplicate!(posted_entry:, reason:, posted_amount:, confidence: "medium")
    existing_extra = extra.is_a?(Hash) ? extra : {}
    return false if existing_extra["potential_posted_match"].present?

    update!(
      extra: existing_extra.merge(
        "potential_posted_match" => {
          "entry_id" => posted_entry.id,
          "reason" => reason,
          "posted_amount" => posted_amount.to_s,
          "confidence" => confidence,
          "detected_at" => Date.current.to_s
        }
      )
    )
    true
  end

  # Merge this transaction with its suggested match and delete this entry: the
  # pending one of a pending/posted pair, or the generated charge of a
  # subscription when the match is its real charge (see replace_subscription_charge!).
  def merge_with_duplicate!
    return false unless has_potential_duplicate?

    posted_entry = potential_duplicate_entry
    return false unless posted_entry

    if subscription_charge_duplicate?
      real_transaction = posted_entry.entryable
      return false unless real_transaction.is_a?(Transaction)

      return real_transaction.replace_subscription_charge!(entry, source: "Transaction#merge_with_duplicate!")
    end

    pending_entry_id = entry.id
    pending_entry_name = entry.name

    # Delete this pending entry completely (no need to keep it around)
    entry.destroy!
    # The entry counted in the account's balances (pre-existing gap: the merge left them stale)
    entry.sync_account_later

    Rails.logger.info("User merged pending entry #{pending_entry_id} (#{pending_entry_name}) with posted entry #{posted_entry.id}")
    true
  end

  # ---------------------------------------------------------------------------
  # Generated subscription charges and their real charges
  # (RecurringTransaction::Reconciler)
  # ---------------------------------------------------------------------------

  SUBSCRIPTION_CHARGE_REASON = "subscription_charge"
  REPLACED_SUBSCRIPTION_CHARGE_KEY = "replaced_subscription_charge"

  # The suggested match is the real charge of this generated subscription charge
  def subscription_charge_duplicate?
    potential_duplicate_reason == SUBSCRIPTION_CHARGE_REASON
  end

  # What this real charge replaced: the generated charge's values, kept so
  # restore_replaced_subscription_charge! can insert it again. nil when it
  # replaced nothing.
  def replaced_subscription_charge
    data = extra.is_a?(Hash) ? extra[REPLACED_SUBSCRIPTION_CHARGE_KEY] : nil
    data.is_a?(Hash) ? data : nil
  end

  def replaced_subscription_charge?
    replaced_subscription_charge.present?
  end

  def replaced_subscription_charge_date
    Date.iso8601(replaced_subscription_charge["date"]) if replaced_subscription_charge&.dig("date").present?
  rescue Date::Error
    nil
  end

  # This real transaction takes the place of a charge generated for a
  # subscription: it gets the generated charge's category (when it has none),
  # tags and notes, and the link to the recurring row. The generated charge's
  # values are stored under extra["replaced_subscription_charge"], then the
  # generated entry is deleted. One transaction under the recurring row's lock,
  # so two runs cannot both replace it. Does not move next_expected_date: the
  # generated charge already recorded the occurrence.
  # Returns false when the generated entry is gone, is no generated charge, or
  # this transaction already belongs to a recurring row.
  def replace_subscription_charge!(generated_entry, source:)
    recurring = generated_entry.entryable.try(:recurring_transaction)
    return false unless recurring && generated_entry.source == "subscription"
    return false if generated_entry.account_id != entry.account_id

    replaced = recurring.with_lock(requires_new: true) do
      generated_entry = Entry.includes(:entryable).find_by(id: generated_entry.id)
      reload
      next false unless generated_entry&.entryable.is_a?(Transaction)
      next false if recurring_transaction_id.present? || replaced_subscription_charge?

      absorb_subscription_charge!(generated_entry, recurring)
      generated_entry.destroy!
      log_subscription_charge_replace(generated_entry, source: source)
      true
    end

    if replaced
      generated_date = Date.iso8601(replaced_subscription_charge["date"])
      entry.account.sync_later(window_start_date: [ generated_date, entry.date ].min)
    end

    replaced
  end

  # Inserts the generated charge this transaction replaced again, from
  # extra["replaced_subscription_charge"], and undoes what the replace carried
  # over (the category it copied, the tags and notes it added, the link to the
  # recurring row). Does not call record_occurrence!, so next_expected_date
  # never moves back.
  #
  # dismiss_pair marks the restored charge as not this real charge, so the
  # reconciler does not replace it again (the user's Restore). An import revert
  # deletes the real charge anyway and passes false.
  #
  # Returns :restored, :not_replaced, :recurring_missing (the recurring row is
  # gone) or :period_taken (the period has a generated charge again).
  def restore_replaced_subscription_charge!(dismiss_pair: true)
    data = replaced_subscription_charge
    return :not_replaced unless data

    family = entry.account.family
    recurring = family.recurring_transactions.find_by(id: data["recurring_transaction_id"])
    return :recurring_missing unless recurring

    restored_entry = nil
    outcome = recurring.with_lock(requires_new: true) do
      reload
      data = replaced_subscription_charge
      next :not_replaced unless data

      date = Date.iso8601(data["date"])
      next :period_taken if recurring.generated_charge_in_period?(date)

      restored_entry = insert_replaced_subscription_charge!(data, recurring, family, dismiss_pair: dismiss_pair)
      undo_subscription_charge_carry_over!(data, recurring)
      :restored
    end

    restored_entry&.sync_account_later
    outcome
  end

  # Dismiss the duplicate suggestion - user says these are NOT the same transaction
  def dismiss_duplicate_suggestion!
    return false unless potential_posted_match_data.present?

    updated_extra = (extra || {}).deep_dup
    updated_extra["potential_posted_match"]["dismissed"] = true
    update!(extra: updated_extra)

    Rails.logger.info("User dismissed duplicate suggestion for entry #{entry.id}")
    true
  end

  # Clear the duplicate suggestion entirely
  def clear_duplicate_suggestion!
    return false unless potential_posted_match_data.present?

    updated_extra = (extra || {}).deep_dup
    updated_extra.delete("potential_posted_match")
    update!(extra: updated_extra)
    true
  end

  # --- Category pickers (recent categories, row tag picker) ---

  # Marks the category as recently used. Called explicitly from the manual
  # category-assignment paths (the pickers, the edit drawer, bulk edit and
  # create-and-assign) after a successful save, and not from an after_save
  # callback, because rules and imports also write category_id and those
  # picks are not the user's. See Category.recently_used_for.
  def record_category_usage!
    category.touch(:last_used_at) if saved_change_to_category_id? && category.present?
  end

  # --- Custom exchange rate (w2-transfers) ---

  # The user's rate from the entry currency into the account currency, as a BigDecimal,
  # or nil when the market rate applies
  def exchange_rate
    raw = extra.is_a?(Hash) ? extra["exchange_rate"] : nil
    return if raw.blank?

    BigDecimal(raw.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # Blank removes the rate (the market rate applies again). A value that is not a number
  # is kept aside for the validation message and never written to extra.
  def exchange_rate=(value)
    @exchange_rate_input = value
    data = (extra.is_a?(Hash) ? extra : {}).except("exchange_rate")

    if value.present?
      rate = parse_exchange_rate(value)
      data["exchange_rate"] = rate.to_s("F") if rate
    end

    self.extra = data
  end

  # A custom rate converts only when the entry and its account differ in currency
  def custom_exchange_rate_applies?
    exchange_rate.present? && entry.present? && entry.account.present? && entry.currency != entry.account.currency
  end

  # Adds or removes one tag while holding the row lock. Assigning tag_ids
  # replaces the whole set, so two quick toggles computed from the same
  # snapshot would drop one of them; per-tagging writes under the lock can't.
  def toggle_tag!(tag)
    with_lock do
      existing = taggings.where(tag: tag)
      existing.exists? ? existing.destroy_all : taggings.create!(tag: tag)
    end
    tags.reset
  end

  private

    # Copies what the generated charge carries onto this real transaction and
    # stores the generated charge's values, with what was carried over so a
    # restore can undo exactly that.
    def absorb_subscription_charge!(generated_entry, recurring)
      generated = generated_entry.entryable
      real_entry = entry
      generated_tag_ids = generated.tag_ids
      generated_notes = generated_entry.notes.to_s.strip

      copy_category = category_id.nil? && generated.category_id.present?
      added_tag_ids = generated_tag_ids - tag_ids
      append_notes = generated_notes.present? && !real_entry.notes.to_s.include?(generated_notes)

      self.category_id = generated.category_id if copy_category
      self.recurring_transaction_id = recurring.id
      self.extra = (extra.is_a?(Hash) ? extra : {}).merge(
        REPLACED_SUBSCRIPTION_CHARGE_KEY => {
          "date" => generated_entry.date.iso8601,
          "amount" => generated_entry.amount.to_s,
          "currency" => generated_entry.currency,
          "name" => generated_entry.name,
          "category_id" => generated.category_id,
          "merchant_id" => generated.merchant_id,
          "tag_ids" => generated_tag_ids,
          "notes" => generated_entry.notes,
          "recurring_transaction_id" => recurring.id,
          "entry_id" => generated_entry.id,
          "account_id" => generated_entry.account_id,
          "carried_over" => {
            "category" => copy_category,
            "tag_ids" => added_tag_ids,
            "notes" => append_notes ? generated_notes : nil
          },
          "replaced_at" => Time.current.iso8601
        }
      )
      save!

      added_tag_ids.each { |tag_id| taggings.create!(tag_id: tag_id) }
      tags.reset

      if append_notes
        real_entry.update!(notes: [ real_entry.notes.presence, generated_notes ].compact.join("\n\n"))
      end
    end

    def log_subscription_charge_replace(generated_entry, source:)
      real_entry = entry

      DebugLogEntry.capture(
        category: "recurring_reconcile",
        level: "info",
        message: "Replaced the generated subscription charge #{generated_entry.id} (#{generated_entry.date}, #{generated_entry.amount} #{generated_entry.currency}) " \
                 "with the real charge #{real_entry.id} (#{real_entry.date}, #{real_entry.amount} #{real_entry.currency})",
        source: source,
        account: real_entry.account,
        metadata: {
          generated_entry_id: generated_entry.id,
          real_entry_id: real_entry.id,
          recurring_transaction_id: recurring_transaction_id,
          generated_date: generated_entry.date.iso8601,
          real_date: real_entry.date.iso8601,
          generated_amount: generated_entry.amount.to_s,
          real_amount: real_entry.amount.to_s,
          currency: real_entry.currency
        }
      )
    end

    def insert_replaced_subscription_charge!(data, recurring, family, dismiss_pair:)
      account = family.accounts.find_by(id: data["account_id"]) || entry.account
      category = family.categories.find_by(id: data["category_id"]) if data["category_id"].present?
      merchant = Merchant.find_by(id: data["merchant_id"]) if data["merchant_id"].present?
      tags = family.tags.where(id: Array(data["tag_ids"])).to_a

      restored_extra = {}
      if dismiss_pair
        restored_extra["potential_posted_match"] = {
          "entry_id" => entry.id,
          "reason" => SUBSCRIPTION_CHARGE_REASON,
          "posted_amount" => entry.amount.to_s,
          "confidence" => "medium",
          "detected_at" => Date.current.to_s,
          "dismissed" => true
        }
      end

      account.entries.create!(
        date: Date.iso8601(data["date"]),
        amount: data["amount"].to_d,
        currency: data["currency"].presence || account.currency,
        name: data["name"].presence || recurring.display_name,
        notes: data["notes"],
        source: "subscription",
        entryable: Transaction.new(
          category: category,
          merchant: merchant,
          recurring_transaction: recurring,
          tags: tags,
          extra: restored_extra
        )
      )
    end

    def undo_subscription_charge_carry_over!(data, recurring)
      carried = data["carried_over"].is_a?(Hash) ? data["carried_over"] : {}
      real_entry = entry

      self.category_id = nil if carried["category"] && category_id.present? && category_id == data["category_id"]
      self.recurring_transaction_id = nil if recurring_transaction_id == recurring.id
      self.extra = extra.except(REPLACED_SUBSCRIPTION_CHARGE_KEY)
      save!

      added_tag_ids = Array(carried["tag_ids"])
      taggings.where(tag_id: added_tag_ids).destroy_all if added_tag_ids.any?
      tags.reset

      appended = carried["notes"].to_s
      if appended.present? && real_entry.notes.to_s.end_with?(appended)
        remaining = real_entry.notes.to_s.delete_suffix(appended).sub(/\n*\z/, "")
        real_entry.update!(notes: remaining.presence)
      end
    end

    def potential_posted_match_data
      return nil unless extra.is_a?(Hash)
      extra["potential_posted_match"]
    end

    def parse_exchange_rate(value)
      UserDecimal.parse(value)
    end

    def exchange_rate_must_be_positive
      return if @exchange_rate_input.blank? && exchange_rate.nil?

      if @exchange_rate_input.present? && parse_exchange_rate(@exchange_rate_input).nil?
        errors.add(:exchange_rate, :not_a_number)
      elsif exchange_rate.present? && !exchange_rate.positive?
        errors.add(:exchange_rate, :greater_than, count: 0)
      end
    end

    def clear_merchant_unlinked_association
      return unless merchant_id.present? && merchant.is_a?(ProviderMerchant)

      family = entry&.account&.family
      return unless family

      FamilyMerchantAssociation.where(family: family, merchant: merchant).delete_all
    end
end
