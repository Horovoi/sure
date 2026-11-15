# One monobank personal API token of a family, with every product it can see:
# cards, currency accounts, FOP accounts and jars (MonobankAccount).
#
# A sync (MonobankItem::Syncer) takes seconds: it refreshes client-info when its
# request slot is free, processes the statement rows already stored, and starts a
# fetch chain (MonobankStatementFetchJob) when there is statement left to fetch.
# The chain makes one request per run and asks for a new sync every few windows,
# so long history never keeps a Sync open.
class MonobankItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable, DestroyableLater

  CHAIN_STALE_AFTER = 5.minutes
  # How long a manual "Sync now" makes every product get a forward window
  FORCE_FORWARD_FOR = 10.minutes

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :access_token, deterministic: true
    encrypts :raw_payload
  end

  belongs_to :family
  has_many :monobank_accounts, dependent: :destroy
  has_many :accounts, through: :monobank_accounts

  validates :name, presence: true
  validates :access_token, presence: true, on: :create

  before_validation :apply_institution_defaults, on: :create
  # Keeps the Sure accounts (as manual ones) when a connection is removed. Not when the
  # family itself is deleted: its accounts go with it.
  before_destroy :unlink_all_accounts, unless: :destroyed_by_association

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active.where(status: :good) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def credentials_configured?
    access_token.present?
  end

  # Holds are imported only when both the app setting and this connection allow it
  def include_pending_holds?
    include_pending? && Rails.configuration.x.monobank.include_pending
  end

  # Stores the latest client-info. The client's name is not kept.
  def upsert_client_info!(client_info)
    snapshot = client_info.to_h.with_indifferent_access
    update!(
      client_id: snapshot[:clientId].presence || client_id,
      raw_payload: snapshot.except(:name),
      last_client_info_at: Time.current
    )
  end

  # IBANs of every product of this client, to see own transfers
  def own_ibans
    monobank_accounts.filter_map(&:iban).to_set
  end

  # --- Linking ---------------------------------------------------------------

  # Links a product to a Sure account the family already has (e.g. a hand-kept card).
  # Transactions from cutover_date come from monobank; earlier history stays as entered.
  def link_existing_account!(monobank_account:, account:, cutover_date: :auto)
    raise ArgumentError, "monobank account belongs to another connection" unless monobank_account.monobank_item_id == id
    raise ArgumentError, "account belongs to another family" unless account.family_id == family_id
    unless account.currency == monobank_account.currency
      raise ArgumentError, "account currency #{account.currency} differs from #{monobank_account.currency}"
    end

    link = Account::ProviderLink.link!(account: account, provider_account: monobank_account, cutover_date: cutover_date)
    monobank_account.update!(ignored: false)
    refresh_pending_account_setup!
    sync_later
    link
  end

  # Creates a new Sure account for a product and links it.
  def create_linked_account!(monobank_account:, accountable_type: nil, subtype: nil, name: nil)
    raise ArgumentError, "monobank account belongs to another connection" unless monobank_account.monobank_item_id == id

    accountable_type = accountable_type.presence || monobank_account.suggested_account_type || "Depository"
    unless Provider::MonobankAdapter.supported_account_types.include?(accountable_type)
      raise ArgumentError, "unsupported account type #{accountable_type}"
    end

    subtype = subtype.presence
    subtype ||= monobank_account.suggested_subtype if accountable_type == monobank_account.suggested_account_type
    opening_date = MonobankItem::FetchPlan.target_start_for(monobank_account).to_date - 1.day

    account = nil
    transaction do
      account = Account.create_and_sync(
        {
          family: family,
          name: name.presence || monobank_account.name,
          balance: 0,
          cash_balance: 0,
          currency: monobank_account.currency,
          accountable_type: accountable_type,
          accountable_attributes: subtype ? { subtype: subtype } : {}
        },
        skip_initial_sync: true,
        opening_balance_date: opening_date
      )
      Account::ProviderLink.link!(account: account, provider_account: monobank_account, cutover_date: :auto)
      monobank_account.update!(ignored: false)
    end

    refresh_pending_account_setup!
    sync_later
    account
  end

  def refresh_pending_account_setup!
    update!(pending_account_setup: monobank_accounts.needs_setup.exists?)
  end

  # --- Fetch chain -----------------------------------------------------------

  def fetch_chain_active?(now: Time.current)
    fetch_chain_token.present? && fetch_chain_heartbeat_at.present? && fetch_chain_heartbeat_at > now - CHAIN_STALE_AFTER
  end

  # Starts a fetch chain when there is a window to fetch and no live chain.
  # Returns the new chain token, or nil.
  def ensure_fetch_chain!(provider: monobank_provider)
    return nil if provider.nil? || requires_update? || scheduled_for_deletion?
    return nil if MonobankItem::FetchPlan.new(self).next_window.nil?

    run_at = [ provider.next_request_slot_at(:statement), Time.current ].max + 1.second
    token = with_lock do
      next nil if fetch_chain_active?

      SecureRandom.uuid.tap do |new_token|
        update!(fetch_chain_token: new_token, fetch_chain_heartbeat_at: run_at)
      end
    end
    return nil unless token

    MonobankStatementFetchJob.set(wait_until: run_at).perform_later(self, token)
    token
  end

  def end_fetch_chain!(token)
    with_lock do
      update!(fetch_chain_token: nil, fetch_chain_heartbeat_at: nil) if fetch_chain_token == token
    end
  end

  def force_forward!
    update!(force_forward_until: Time.current + FORCE_FORWARD_FOR)
  end

  # Statement pages left to fetch, and about how long that takes
  def backfill_progress
    remaining = MonobankItem::FetchPlan.new(self).windows_remaining
    interval = monobank_provider&.min_request_interval || Provider::Monobank::MIN_REQUEST_INTERVAL

    { windows_remaining: remaining, eta_seconds: (remaining * (interval + 1)).ceil, chain_active: fetch_chain_active? }
  rescue Provider::Error
    { windows_remaining: 0, eta_seconds: 0, chain_active: fetch_chain_active? }
  end

  # --- Processing ------------------------------------------------------------

  # Writes balances and entries of every linked, visible product from stored rows
  def process_accounts
    monobank_accounts.includes(account_provider: :account).filter_map do |monobank_account|
      account = monobank_account.current_account
      next unless account && Account::VISIBLE_STATUSES.include?(account.status)

      result = MonobankAccount::Processor.new(monobank_account).process
      if result.is_a?(Hash) && result[:failed].to_i.positive?
        capture_error("monobank rows could not be booked", nil, monobank_account: monobank_account,
                      metadata: { failed: result[:failed], errors: result[:errors] })
        next { monobank_account_id: monobank_account.id, success: false, result: result,
               error: I18n.t("monobank_items.errors.account_processing_failed") }
      end

      { monobank_account_id: monobank_account.id, success: true, result: result }
    rescue => e
      capture_error("Failed to process monobank account", e, monobank_account: monobank_account)
      { monobank_account_id: monobank_account.id, success: false, error: I18n.t("monobank_items.errors.account_processing_failed") }
    end
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.visible.map do |account|
      account.sync_later(parent_sync: parent_sync, window_start_date: window_start_date, window_end_date: window_end_date)
      { account_id: account.id, success: true }
    rescue => e
      capture_error("Failed to schedule account sync", e)
      { account_id: account.id, success: false, error: I18n.t("monobank_items.errors.account_sync_schedule_failed") }
    end
  end

  # --- Display ---------------------------------------------------------------

  def has_completed_initial_setup?
    accounts.any?
  end

  def sync_status_summary
    counts = account_counts
    if counts[:total].zero?
      I18n.t("monobank_items.sync_status.no_accounts")
    elsif counts[:unlinked].zero?
      I18n.t("monobank_items.sync_status.all_synced", count: counts[:linked])
    else
      I18n.t("monobank_items.sync_status.partial", linked: counts[:linked], unlinked: counts[:unlinked])
    end
  end

  def linked_accounts_count = account_counts[:linked]
  def unlinked_accounts_count = account_counts[:unlinked]
  def total_accounts_count = account_counts[:total]

  def institution_display_name
    institution_name.presence || name
  end

  def connected_institutions
    accounts.any? ? [ { "name" => institution_display_name, "domain" => institution_domain } ] : []
  end

  def institution_summary
    institution_display_name
  end

  def capture_error(message, error, monobank_account: nil, level: "error", metadata: {})
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: level,
      message: message,
      source: self.class.name,
      provider_key: "monobank",
      family: family,
      account_provider: monobank_account&.account_provider,
      metadata: { monobank_item_id: id, monobank_account_id: monobank_account&.id,
                  error_class: error&.class&.name, error_message: error&.message,
                  failure_code: error.respond_to?(:failure_code) ? error.failure_code : nil }.merge(metadata).compact
    )
  end

  private
    def apply_institution_defaults
      self.institution_name ||= MonobankAccount::INSTITUTION_NAME
      self.institution_domain ||= MonobankAccount::INSTITUTION_DOMAIN
      self.institution_url ||= "https://#{MonobankAccount::INSTITUTION_DOMAIN}"
    end

    def account_counts
      @account_counts ||= begin
        rows = monobank_accounts.left_joins(:account_provider).pluck(Arel.sql("account_providers.id IS NOT NULL"), :ignored)
        {
          linked: rows.count { |linked, _| linked },
          unlinked: rows.count { |linked, ignored| !linked && !ignored },
          total: rows.size
        }
      end
    end

    def unlink_all_accounts
      unlink_all!
    end
end
