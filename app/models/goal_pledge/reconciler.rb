# Keeps open pledges when the money arrives (w2-goals goal-pledges, ported from
# upstream). The fork has no bank providers, so it is called from the manual paths:
#
# - Account::ReconciliationManager after a valuation is saved (a balance update, the
#   UI, the API and the record_balance tool), with the balance change it recorded
# - Account::CurrentBalanceManager when a balance update adjusts the opening balance
#   instead (a cash account without reconciliations), through .for_balance_change
# - Transaction after_create_commit, for a manual transaction or transfer
# - Import after publish, for the rows a bulk insert wrote without callbacks
#
# Older pledges are kept first, and one entry keeps at most one pledge. A failure is
# logged and reported, never raised into the write it is hooked onto.
class GoalPledge::Reconciler
  # A balance change with no entry of its own (an opening-balance adjustment)
  BalanceChange = Data.define(:account_id, :currency, :date, :delta)

  attr_reader :entry

  class << self
    def for_balance_change(account:, delta:, date: Date.current)
      new(BalanceChange.new(account_id: account.id, currency: account.currency, date: date, delta: delta))
    end

    # The import's new inflow transactions on accounts that have an open pledge
    def reconcile_import(import)
      account_ids = GoalPledge.pending.distinct.pluck(:account_id)
      return if account_ids.empty?

      import.entries
            .where(entryable_type: "Transaction", account_id: account_ids, excluded: false)
            .where("entries.amount < 0")
            .includes(:entryable)
            .find_each { |entry| new(entry).run }
    end

    # Cheap guard for the per-transaction hook
    def pending_on?(account_id)
      account_id.present? && GoalPledge.pending.where(account_id: account_id).exists?
    end
  end

  # `valuation_delta` is the balance change a valuation recorded, from the manager that
  # knows the prior balance. A transaction's own amount is already the contribution.
  def initialize(entry, valuation_delta: nil)
    @entry = entry
    @valuation_delta = valuation_delta
  end

  # The pledge it kept, or nil
  def run
    return unless eligible?
    return if already_stamped?

    candidates.each do |pledge|
      next unless matches?(pledge)

      begin
        resolve(pledge)
        Rails.logger.info("GoalPledge #{pledge.id} kept by #{source_label}")
        return pledge
      rescue GoalPledge::NotOpenError, GoalPledge::AlreadyClaimedError,
             ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, AASM::InvalidTransition => e
        # Another worker got there first: try the next pledge
        Rails.logger.warn("GoalPledge #{pledge.id} not kept: #{e.class}: #{e.message}")
      end
    end

    nil
  rescue StandardError => e
    Rails.logger.error("GoalPledge::Reconciler failed for #{source_label}: #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    nil
  end

  private
    def balance_change?
      entry.is_a?(BalanceChange)
    end

    def valuation?
      !balance_change? && entry.entryable.is_a?(Valuation)
    end

    def transaction?
      !balance_change? && entry.entryable.is_a?(Transaction)
    end

    def eligible?
      return false if entry.nil? || entry.account_id.blank?
      return entry.delta.present? if balance_change?
      return false if entry.excluded?

      transaction? || valuation?
    end

    def already_stamped?
      transaction? && entry.entryable.extra&.dig("goal", "pledge_id").present?
    end

    # Open pledges on the account, of a goal in the account's own family
    def candidates
      scope = GoalPledge.pending
                        .joins(:goal, :account)
                        .where(account_id: entry.account_id)
                        .where("accounts.family_id = goals.family_id")
                        # The account still funds the goal
                        .where("EXISTS (SELECT 1 FROM goal_accounts WHERE goal_accounts.goal_id = goal_pledges.goal_id AND goal_accounts.account_id = goal_pledges.account_id)")
                        .includes(:goal, :account)
                        .order(:created_at, :id)
      scope = scope.where(kind: "manual_save") unless transaction?
      scope.to_a
    end

    def matches?(pledge)
      if balance_change?
        pledge.matches_balance_change?(account_id: entry.account_id, delta: entry.delta, currency: entry.currency, date: entry.date)
      else
        pledge.matches?(entry, valuation_delta: @valuation_delta)
      end
    end

    def resolve(pledge)
      if transaction?
        pledge.resolve_with!(entry.entryable)
      else
        pledge.resolve_with_valuation!(entry)
      end
    end

    def source_label
      return "balance change on account #{entry&.account_id}" if balance_change?

      "entry #{entry&.id}"
    end
end
