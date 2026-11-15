class Account < ApplicationRecord
  include AASM, Syncable, Monetizable, Chartable, Linkable, Enrichable, Anchorable, Reconcileable, TaxTreatable

  validates :name, :balance, :currency, presence: true

  belongs_to :family
  belongs_to :import, optional: true

  has_many :import_mappings, as: :mappable, dependent: :destroy, class_name: "Import::Mapping"
  has_many :entries, dependent: :destroy
  has_many :transactions, through: :entries, source: :entryable, source_type: "Transaction"
  has_many :valuations, through: :entries, source: :entryable, source_type: "Valuation"
  has_many :trades, through: :entries, source: :entryable, source_type: "Trade"
  has_many :holdings, dependent: :destroy
  has_many :balances, dependent: :destroy
  # Recurring rows only point at the account (the one to post to, or the one the pattern was seen on)
  has_many :default_recurring_transactions, class_name: "RecurringTransaction", foreign_key: :default_account_id, inverse_of: :default_account, dependent: :nullify
  has_many :inferred_recurring_transactions, class_name: "RecurringTransaction", foreign_key: :inferred_account_id, inverse_of: :inferred_account, dependent: :nullify
  # Savings goals (w2-goals). The links go before the account: their FK is RESTRICT.
  has_many :goal_accounts, dependent: :destroy
  has_many :goals, through: :goal_accounts
  # Goal pledges (w2-goals goal-pledges). Before the account too: their FK is RESTRICT.
  has_many :goal_pledges, dependent: :destroy

  monetize :balance, :cash_balance

  enum :classification, { asset: "asset", liability: "liability" }, validate: { allow_nil: true }

  # Statuses of accounts the user sees in lists and reports. Disabled accounts and
  # accounts being deleted are hidden. Use `visible`, or `visible_status_sql` in raw SQL.
  VISIBLE_STATUSES = %w[draft active].freeze

  scope :visible, -> { where(status: VISIBLE_STATUSES) }

  # A deletion still pending after this long lost its job; the stale work reaper restores
  # the account (disabled, data intact) so it can be deleted again instead of hanging
  STALE_DELETION_AFTER = 1.hour
  scope :stale_deletion, -> { where(status: "pending_deletion", updated_at: ...STALE_DELETION_AFTER.ago) }

  # Accounts counted in totals such as net worth. A draft (a property whose setup
  # wizard is not finished) is listed, but its balance is not counted yet.
  scope :counted_in_totals, -> { where(status: "active") }

  # Accounts counted in past net worth: active ones, and disabled ones for the days
  # before they were disabled (disabled_at). Drafts and accounts being deleted stay out.
  # BalanceSheet::HistoricalAccountScope gives the per-account windows.
  HISTORICAL_STATUSES = %w[active disabled].freeze
  scope :counted_in_history, -> { where(status: HISTORICAL_STATUSES) }

  # w3-reports exclude-from-reports: accounts the user keeps in reports. An excluded
  # account stays active and listed (sidebar, accounts page, its own page), but no total
  # counts it: net worth, cash flow, budgets, investments and the AI read tools. Combine
  # it with counted_in_totals or counted_in_history; use `included_in_reports_sql` in raw SQL.
  scope :included_in_reports, -> { where(exclude_from_reports: false) }
  scope :excluded_from_reports, -> { where(exclude_from_reports: true) }

  scope :assets, -> { where(classification: "asset") }
  scope :liabilities, -> { where(classification: "liability") }
  scope :alphabetically, -> { order(:name) }
  scope :manual, -> {
    left_joins(:account_providers)
      .where(account_providers: { id: nil })
      .where(plaid_account_id: nil)
  }

  scope :visible_manual, -> {
    visible.manual
  }

  scope :listable, -> { where.not(status: :pending_deletion) }

  scope :listable_manual, -> { manual.listable }

  # Accounts that no enabled bank connection syncs: manual accounts, and accounts linked
  # to a provider that is switched off (see BankConnections). The accounts page lists
  # them with the manual accounts and the family sync syncs them like manual ones, so an
  # account keeps its balances while its provider is off.
  scope :outside_enabled_providers, -> {
    classes = BankConnections.enabled_account_class_names
    scope = all
    scope = scope.where.not(id: AccountProvider.where(provider_type: classes).select(:account_id)) if classes.any?
    scope = scope.where(plaid_account_id: nil) if BankConnections.enabled?(:plaid)
    scope
  }

  has_one_attached :logo

  # w2-transfers default-account: users whose new entries start in this account. The
  # foreign key clears the link when the account row goes; leaving the active state clears
  # it too, so a disabled account is never preselected.
  has_many :default_for_users, class_name: "User", foreign_key: :default_account_id, inverse_of: :default_account, dependent: :nullify
  after_update_commit :release_as_default_account, if: -> { saved_change_to_status? && !active? }

  # w3-reports exclude-from-reports: a confirmed transfer with this account on one side
  # takes its kinds from the flag (Transfer.outflow_kind_for), so they follow a toggle.
  # In the same database transaction as the flag, so the two never disagree.
  after_update :reapply_transfer_kinds, if: :saved_change_to_exclude_from_reports?

  delegated_type :accountable, types: Accountable::TYPES, dependent: :destroy
  delegate :subtype, to: :accountable, allow_nil: true

  # Writer for subtype that delegates to the accountable, so forms can set
  # `account[subtype]` directly.
  #
  # On create the accountable is not built yet, and mass assignment applies
  # attributes in the order they arrive. Two cases:
  #
  #   1. The type is already known: build the accountable now so the value lands
  #      on it. A later `accountable_attributes` assignment (update_only) updates
  #      that same record instead of building a new one.
  #   2. `subtype` comes before `accountable_type` (the order `account_params`
  #      permits them): hold the value and apply it from `accountable_type=`.
  def subtype=(value)
    self.accountable = accountable_class.new if accountable.nil? && accountable_type.present?

    if accountable
      accountable.subtype = value
    else
      @deferred_subtype = value
    end
  end

  def accountable_type=(value)
    super

    if defined?(@deferred_subtype)
      pending = remove_instance_variable(:@deferred_subtype)
      self.subtype = pending
    end
  end

  accepts_nested_attributes_for :accountable, update_only: true

  # delegated_type builds the accountable with `accountable_type.constantize`, and
  # accountable_type often comes from request params. Allow only the account types.
  def accountable_class
    Accountable.from_type(accountable_type) || raise(ArgumentError, "Unknown account type: #{accountable_type.inspect}")
  end

  # Account state machine
  aasm column: :status do
    state :active, initial: true, before_enter: :clear_disabled_at
    state :draft
    state :disabled, before_enter: :stamp_disabled_at
    state :pending_deletion

    event :activate do
      transitions from: [ :draft, :disabled ], to: :active
    end

    event :disable do
      transitions from: [ :draft, :active ], to: :disabled
    end

    event :enable do
      transitions from: :disabled, to: :active
    end

    event :mark_for_deletion do
      transitions from: [ :draft, :active, :disabled ], to: :pending_deletion
    end

    # A deletion that failed leaves the account disabled (hidden from totals but listed,
    # with its data intact) so the user can look at it or delete it again.
    event :restore do
      transitions from: :pending_deletion, to: :disabled
    end
  end

  class << self
    # SQL condition for `visible`, for raw SQL that names the accounts table differently.
    #   Account.visible_status_sql("a") # => %q("a".status IN ('draft','active'))
    def visible_status_sql(table = table_name)
      "#{connection.quote_table_name(table)}.status IN (#{VISIBLE_STATUSES.map { |s| connection.quote(s) }.join(',')})"
    end

    # SQL condition for `included_in_reports`, for raw SQL that names the accounts table differently.
    #   Account.included_in_reports_sql("a") # => %q("a".exclude_from_reports = FALSE)
    def included_in_reports_sql(table = table_name)
      "#{connection.quote_table_name(table)}.exclude_from_reports = FALSE"
    end

    # opening_balance_date: the day the entered balance (or a loan's original
    # balance) applies to. nil keeps the manager's default, two years ago.
    def create_and_sync(attributes, skip_initial_sync: false, opening_balance_date: nil)
      attributes[:accountable_attributes] ||= {} # Ensure accountable is created, even if empty
      # Default cash_balance to balance unless explicitly provided (e.g., Crypto sets it to 0)
      attrs = attributes.dup
      attrs[:cash_balance] = attrs[:balance] unless attrs.key?(:cash_balance)
      account = new(attrs)
      # Presence is read from the raw value: a blank form field arrives as "" and
      # would convert to a present-looking 0.
      raw_initial_balance = attributes.dig(:accountable_attributes, :initial_balance)
      initial_balance = raw_initial_balance.to_d if raw_initial_balance.present?

      transaction do
        account.save!

        manager = Account::OpeningBalanceManager.new(account)
        result = manager.set_opening_balance(
          balance: initial_balance || account.balance,
          date: opening_balance_date
        )
        raise result.error if result.error

        # A loan created with its original principal opens at that principal, and the
        # opening anchor is its only entry: the first sync would walk forward from it and
        # replace the current balance the user typed. Anchor today's balance too.
        #
        # Only when the opening anchor is on an earlier day. A reconciliation on the
        # anchor's own date is refused (an anchor is never overwritten), so on that day
        # the opening balance wins.
        if initial_balance && initial_balance != account.balance && manager.opening_date < Date.current
          reconciliation = Account::ReconciliationManager.new(account).reconcile_balance(
            balance: account.balance,
            date: Date.current
          )
          raise reconciliation.error_message unless reconciliation.success?
        end
      end

      # Skip initial sync for linked accounts - the provider sync will handle balance creation
      # after the correct currency is known
      account.sync_later unless skip_initial_sync
      account
    end


    def create_from_enable_banking_account(enable_banking_account, account_type, subtype = nil)
      # Get the balance from Enable Banking
      balance = enable_banking_account.current_balance || 0

      # Enable Banking may return negative balances for liabilities
      # Sure expects positive balances for liabilities
      if account_type == "CreditCard" || account_type == "Loan"
        balance = balance.abs
      end

      cash_balance = balance

      attributes = {
        family: enable_banking_account.enable_banking_item.family,
        name: enable_banking_account.name,
        balance: balance,
        cash_balance: cash_balance,
        currency: enable_banking_account.currency || "EUR"
      }

      accountable_attributes = {}
      accountable_attributes[:subtype] = subtype if subtype.present?

      # Skip initial sync - provider sync will handle balance creation with correct currency
      create_and_sync(
        attributes.merge(
          accountable_type: account_type,
          accountable_attributes: accountable_attributes
        ),
        skip_initial_sync: true
      )
    end

    def create_from_coinbase_account(coinbase_account)
      # All Coinbase accounts are crypto exchange accounts
      family = coinbase_account.coinbase_item.family

      # Extract native balance and currency from Coinbase (e.g., USD, EUR, GBP)
      native_balance = coinbase_account.raw_payload&.dig("native_balance", "amount").to_d
      native_currency = coinbase_account.raw_payload&.dig("native_balance", "currency") || family.currency

      attributes = {
        family: family,
        name: coinbase_account.name,
        balance: native_balance,
        cash_balance: 0, # No cash - all value is in holdings
        currency: native_currency,
        accountable_type: "Crypto",
        accountable_attributes: {
          subtype: "exchange",
          tax_treatment: "taxable"
        }
      }

      # Skip initial sync - provider sync will handle balance/holdings creation
      create_and_sync(attributes, skip_initial_sync: true)
    end
  end

  def institution_name
    read_attribute(:institution_name).presence || provider&.institution_name
  end

  def institution_domain
    read_attribute(:institution_domain).presence || provider&.institution_domain
  end

  def logo_url
    provider&.logo_url
  end

  # Whether the new-entry forms may preselect this account (w2-transfers default-account):
  # the transaction form lists only manual, active accounts
  def eligible_as_default?
    active? && manual?
  end

  # Idempotent: a second click while the deletion is queued does nothing
  def destroy_later
    with_lock do
      return unless may_mark_for_deletion?
      mark_for_deletion!
    end
    DestroyJob.perform_later(self)
  end

  # Syncs skip records that are being deleted (Sync#perform checks this)
  def scheduled_for_deletion?
    pending_deletion?
  end

  # Called by DestroyJob when the destroy raised or was halted
  def recover_from_failed_destroy!
    reload
    restore! if may_restore?
  end

  def current_holdings
    holdings
      .where(currency: currency)
      .where.not(qty: 0)
      .where(
        id: holdings.select("DISTINCT ON (security_id) id")
                    .where(currency: currency)
                    .order(:security_id, date: :desc)
      )
      .order(amount: :desc)
  end

  def start_date
    first_entry_date = entries.minimum(:date) || Date.current
    first_entry_date - 1.day
  end

  def lock_saved_attributes!
    super
    accountable.lock_saved_attributes!
  end

  # Matches the `counted_in_totals` scope.
  def counted_in_totals?
    active?
  end

  # Matches the `included_in_reports` scope.
  def included_in_reports?
    !exclude_from_reports?
  end

  def first_valuation
    entries.valuations.order(:date).first
  end

  def first_valuation_amount
    first_valuation&.amount_money || balance_money
  end

  # The day the provider took over an account that had manual history
  # (Account::ProviderLink), or nil
  def provider_cutover_date
    if account_providers.loaded?
      account_providers.filter_map(&:cutover_date).max
    else
      account_providers.maximum(:cutover_date)
    end
  end

  # How the account's balances are calculated (Account::Syncer):
  # - :forward from the opening anchor: manual accounts, accounts linked to a provider
  #   that is switched off, and a linked account with manual history (a cutover date)
  #   until the provider wrote its first balance;
  # - :reverse from the provider's current balance: linked accounts;
  # - :cutover: forward up to the day before the cutover date, then reverse from the
  #   provider's balance (Balance::CutoverCalculator).
  def balance_strategy
    return :forward unless linked?
    # A provider that is switched off writes no balance: its last current anchor is old,
    # and the forward calculation keeps it as a balance on its day so new entries count
    return :forward unless synced_by_enabled_provider?

    cutover = provider_cutover_date
    return :reverse if cutover.nil?
    return :forward unless has_current_anchor?

    cutover > opening_anchor_date ? :cutover : :reverse
  end

  # Whether a bank connection that is switched on (BankConnections) keeps this account
  def synced_by_enabled_provider?
    return true if plaid_account_id.present? && BankConnections.enabled?(:plaid)

    classes = BankConnections.enabled_account_class_names
    return false if classes.empty?

    providers = account_providers.loaded? ? account_providers : account_providers.select(:provider_type)
    providers.any? { |link| classes.include?(link.provider_type) }
  end

  # Whether the linked provider's balance already counts open holds, so the balances
  # calculated back from it must count pending entries too
  def provider_balance_includes_pending?
    providers = account_providers.loaded? ? account_providers : account_providers.select(:provider_type)
    providers.any? { |link| BankConnections.provider_for_account_class(link.provider_type)&.balance_includes_pending? }
  end

  # Get short version of the subtype label
  def short_subtype_label
    accountable_class.short_subtype_label_for(subtype) || accountable_class.display_name
  end

  # Get long version of the subtype label
  def long_subtype_label
    accountable_class.long_subtype_label_for(subtype) || accountable_class.display_name
  end

  # Determines if this account supports manual trade entry
  # Investment accounts always support trades; Crypto only if subtype is "exchange"
  def supports_trades?
    return true if investment?
    return accountable.supports_trades? if crypto? && accountable.respond_to?(:supports_trades?)
    false
  end

  # The balance type determines which "component" of balance is being tracked.
  # This is primarily used for balance related calculations and updates.
  #
  # "Cash" = "Liquid"
  # "Non-cash" = "Illiquid"
  # "Investment" = A mix of both, including brokerage cash (liquid) and holdings (illiquid)
  def balance_type
    case accountable_type
    when "Depository", "CreditCard"
      :cash
    when "Property", "Vehicle", "OtherAsset", "Loan", "OtherLiability"
      :non_cash
    when "Investment", "Crypto"
      :investment
    else
      raise "Unknown account type: #{accountable_type}"
    end
  end

  # --- Savings goals (w2-goals) ----------------------------------------------
  # Fixed earmark this account has reserved across every goal still holding its money
  # (whole-balance links reserve no fixed slice). Same states as
  # Goal.pooled_allocations_for, so the two never disagree.
  def goal_earmarked_total
    GoalAccount.joins(:goal)
               .where(account_id: id)
               .where.not(allocated_amount: nil)
               .where.not(goals: { state: Goal::RELEASED_STATES })
               .sum(:allocated_amount)
               .to_d
  end

  # Headroom left to earmark before the fixed earmarks exceed the balance. Negative
  # means the account is over-earmarked (the goals then progress pro rata).
  def free_to_earmark
    balance.to_d - goal_earmarked_total
  end

  # How a pledge into this account is kept (goal-pledges). A manual cash account's
  # pledge is also kept by a balance update. An investment or crypto account's is kept
  # only by an inflow transaction (a rise in its balance may be the market), and so is
  # a provider-linked account's, whose balance the provider writes.
  def default_pledge_kind
    linked? || balance_type == :investment ? "transfer" : "manual_save"
  end
  # --- end savings goals -----------------------------------------------------

  private
    def release_as_default_account
      User.where(default_account_id: id).update_all(default_account_id: nil, updated_at: Time.current)
    end

    def reapply_transfer_kinds
      Transfer.reapply_kinds_for!(self)
    end

    # Runs on every entry to disabled: the disable event, and the restore after a failed
    # deletion. A restore keeps the stamp of a disable that came before the deletion, so
    # the days the account was already out stay out. The state is still the old one here.
    def stamp_disabled_at
      return if aasm.current_state == :pending_deletion && disabled_at.present?

      self.disabled_at = Time.current
    end

    # Enable and activate bring the account back into net worth, for every day
    def clear_disabled_at
      self.disabled_at = nil
    end
end
