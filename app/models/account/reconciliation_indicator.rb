# How far the user has checked an account's transactions against its statements
# (Entry#reconciled_status), for the account header (w3-toolstrx reconciliation-status,
# decision 26). Only a manual account with at least one transaction gets one; excluded
# transactions do not count.
#
# Fork-native: upstream also reads statement-level reconciliation (AccountStatement),
# which this fork does not have.
class Account::ReconciliationIndicator
  attr_reader :account, :unreconciled_count, :cleared_count, :reconciled_count

  class << self
    # { account_id => indicator }, with no key for an account that gets none. One
    # grouped count for all the accounts.
    def for_accounts(accounts)
      manual_ids = Account.manual.where(id: accounts.map(&:id)).pluck(:id).to_set
      return {} if manual_ids.empty?

      # A split transaction is one statement line: its parent counts (though excluded from
      # the figures), its parts do not
      counts = Entry.where(account_id: manual_ids.to_a, entryable_type: "Transaction", parent_entry_id: nil)
        .where("entries.excluded = false OR #{Entry.split_parent_sql}")
        .group(:account_id, :reconciled_status)
        .count

      accounts.each_with_object({}) do |account, indicators|
        next unless manual_ids.include?(account.id)

        by_status = Entry::RECONCILED_STATUS_CYCLE.index_with { |status| counts.fetch([ account.id, status ], 0) }
        indicator = new(account, **by_status.transform_keys { |status| :"#{status}_count" })
        indicators[account.id] = indicator if indicator.total_count.positive?
      end
    end

    def for(account)
      for_accounts([ account ])[account.id]
    end
  end

  def initialize(account, unreconciled_count:, cleared_count:, reconciled_count:)
    @account = account
    @unreconciled_count = unreconciled_count
    @cleared_count = cleared_count
    @reconciled_count = reconciled_count
  end

  def total_count
    unreconciled_count + cleared_count + reconciled_count
  end

  # Transactions still to check: not seen on a statement yet, or seen but not reconciled
  def open_count
    unreconciled_count + cleared_count
  end

  # :matched when every transaction is reconciled, else :needs_attention
  def status
    open_count.zero? ? :matched : :needs_attention
  end

  def matched?
    status == :matched
  end
end
