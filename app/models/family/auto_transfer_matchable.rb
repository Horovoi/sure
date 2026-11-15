module Family::AutoTransferMatchable
  # How far a cross-currency pair may stray from the converted amount (bank FX spread and
  # the gap between the transaction's moment and the day's stored rate)
  EXCHANGE_RATE_TOLERANCE = 0.05

  # The "Transfer?" hint in the transaction list is unprompted, so it is much narrower than
  # the matcher dialog it opens: on a real multi-currency history the dialog's 30 days
  # flagged mostly coincidental small purchases, while 2 days and a 3% FX band kept mainly
  # genuine currency conversions.
  TRANSFER_HINT_DATE_WINDOW = 2
  TRANSFER_HINT_EXCHANGE_RATE_TOLERANCE = 0.03

  # Pairs of transactions that look like the two legs of one transfer: opposite amounts in
  # two visible accounts of this family, within date_window days, not already in a transfer.
  #
  # Same currency: the amounts must be exactly opposite. Different currencies: the inflow
  # must be within EXCHANGE_RATE_TOLERANCE of the outflow converted at the outflow's date,
  # by the nearest-rate rule (ExchangeRate.rate_sql). The direct pair rate comes first; with
  # none, the cross rate through the family currency (from -> family / to -> family), since
  # rates are stored into the family currency. A pair with no rate at all is never matched:
  # there is no rate of 1 to fall back on.
  #
  # restrict_cross_currency_to_routes (the automatic path): a cross-currency guess is a
  # coincidence check, and nobody reviews it before it shows up. It is allowed only when both
  # accounts are linked to a provider, or the user already confirmed a transfer between the
  # same two accounts in the same direction (a known route). Every account here is manual,
  # so in practice: known routes only. The manual "match as transfer" dialog leaves this off,
  # because the user confirms the pair there themselves.
  #
  # account_id limits the pairs to those with a leg in that account (after an account sync).
  # transaction_ids limits them to those with a leg among these transactions (one page of
  # the list, for the "Transfer?" hint); an empty list matches nothing.
  #
  # Exact same-currency pairs rank before cross-currency guesses, then the closest dates, so
  # a greedy run never lets a guess one day closer claim a transaction whose exact
  # counterpart is a day later.
  def transfer_match_candidates(date_window: 4, account_id: nil, restrict_cross_currency_to_routes: false, exchange_rate_tolerance: EXCHANGE_RATE_TOLERANCE, transaction_ids: nil)
    date_window = Integer(date_window)
    tolerance = Float(exchange_rate_tolerance)

    scope = Entry.select([
      "inflow_candidates.entryable_id as inflow_transaction_id",
      "outflow_candidates.entryable_id as outflow_transaction_id",
      "ABS(inflow_candidates.date - outflow_candidates.date) as date_diff",
      "(CASE WHEN inflow_candidates.currency = outflow_candidates.currency THEN 0 ELSE 1 END) as match_rank"
    ]).from("entries inflow_candidates")
      .joins(Entry.sanitize_sql_array([ "
        JOIN entries outflow_candidates ON (
          inflow_candidates.amount < 0 AND
          outflow_candidates.amount > 0 AND
          inflow_candidates.account_id <> outflow_candidates.account_id AND
          inflow_candidates.date BETWEEN outflow_candidates.date - :date_window AND outflow_candidates.date + :date_window
        )
      ", { date_window: date_window } ])).joins("
        LEFT JOIN transfers existing_transfers ON (
          existing_transfers.inflow_transaction_id = inflow_candidates.entryable_id OR
          existing_transfers.outflow_transaction_id = outflow_candidates.entryable_id
        )
      ")
      .joins("LEFT JOIN rejected_transfers ON (
        rejected_transfers.inflow_transaction_id = inflow_candidates.entryable_id AND
        rejected_transfers.outflow_transaction_id = outflow_candidates.entryable_id
      )")
      .joins("JOIN accounts inflow_accounts ON inflow_accounts.id = inflow_candidates.account_id")
      .joins("JOIN accounts outflow_accounts ON outflow_accounts.id = outflow_candidates.account_id")
      .where("inflow_accounts.family_id = ? AND outflow_accounts.family_id = ?", self.id, self.id)
      .where(Account.visible_status_sql("inflow_accounts"))
      .where(Account.visible_status_sql("outflow_accounts"))
      .where("inflow_candidates.entryable_type = 'Transaction' AND outflow_candidates.entryable_type = 'Transaction'")
      .where(
        transfer_amounts_match_sql(restrict_cross_currency_to_routes: restrict_cross_currency_to_routes),
        family_currency: primary_currency_code, min_ratio: 1 - tolerance, max_ratio: 1 + tolerance
      )
      .where(existing_transfers: { id: nil })

    if account_id
      scope = scope.where("inflow_candidates.account_id = :account_id OR outflow_candidates.account_id = :account_id", account_id: account_id)
    end

    unless transaction_ids.nil?
      # IN () is invalid SQL, so an empty list binds a NULL that matches nothing
      ids = transaction_ids.to_a.presence || [ nil ]
      scope = scope.where("inflow_candidates.entryable_id IN (:ids) OR outflow_candidates.entryable_id IN (:ids)", ids: ids)
    end

    scope.order("match_rank ASC, date_diff ASC")
  end

  # Pairs unmatched transactions as pending transfers. A pending transfer is a suggestion:
  # it leaves both legs' kinds alone until the user confirms it (Transfer confirm event), so
  # an unreviewed guess never moves budgets or reports.
  #
  # Does nothing while the family has auto-matching turned off. With an account, only the
  # pairs that have a leg in that account (the account's own sync).
  #
  # Runs after every account sync and after the family sync, so several runs can overlap.
  # A family-level advisory lock serializes them (and Transfer#reject!), and each pair is created
  # in its own savepoint, so a pair that loses a race is skipped without aborting the run.
  def auto_match_transfers!(account: nil)
    return if auto_match_transfers_disabled?

    Transfer.transaction do
      lock_transfer_matching!

      used_transaction_ids = Set.new

      auto_match_candidates(account: account).each do |match|
        next if used_transaction_ids.include?(match.inflow_transaction_id) ||
               used_transaction_ids.include?(match.outflow_transaction_id)

        if create_auto_matched_transfer(match)
          used_transaction_ids << match.inflow_transaction_id
          used_transaction_ids << match.outflow_transaction_id
        end
      end
    end
  end

  # --- "Transfer?" hint (w2-transfers transfer-hints) ---

  # Which of `transactions` (one page of the list) have a likely transfer counterpart, so
  # the row can point to the "match as transfer" dialog. A set of transaction ids.
  def transaction_ids_with_transfer_candidates(transactions)
    page_ids = transactions.map(&:id).to_set

    transfer_hint_candidates(transactions).each_with_object(Set.new) do |candidate, ids|
      [ candidate.inflow_transaction_id, candidate.outflow_transaction_id ].each { |id| ids << id if page_ids.include?(id) }
    end
  end

  # "Not a transfer" on a hint: rejects every pair the hint offered for this transaction,
  # the same record a rejected auto-match leaves, so neither the hint nor auto-match offers
  # them again. The manual dialog still lists them (last).
  def dismiss_transfer_hint!(transaction)
    RejectedTransfer.transaction do
      transfer_hint_candidates([ transaction ]).each do |candidate|
        RejectedTransfer.find_or_create_by!(
          inflow_transaction_id: candidate.inflow_transaction_id,
          outflow_transaction_id: candidate.outflow_transaction_id
        )
      end
    end
  end

  # The switch on the preferences page reads as "on"; the column stores the opt-out
  def auto_match_transfers_enabled
    !auto_match_transfers_disabled?
  end
  alias_method :auto_match_transfers_enabled?, :auto_match_transfers_enabled

  def auto_match_transfers_enabled=(value)
    self.auto_match_transfers_disabled = !ActiveModel::Type::Boolean.new.cast(value)
  end

  # Serializes auto-matching and rejecting transfers for this family until the current
  # database transaction ends.
  def lock_transfer_matching!
    raise "lock_transfer_matching! must run inside a transaction" unless self.class.connection.transaction_open?

    self.class.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", "auto_match_transfers:#{id}" ])
    )
  end

  private
    # The hint's pairs for `transactions`: the narrow hint window and FX band, no rejected
    # pair, no excluded entry or transfer fee, and both legs in the same category (or both
    # uncategorized). On a real history every coincidental pair (a food delivery against a
    # utility refund) had different categories on its legs, every genuine one the same.
    def transfer_hint_candidates(transactions)
      unmatched_ids = transactions.reject { |txn| txn.transfer? || txn.transfer.present? || txn.fee_transfer_id.present? }.map(&:id)
      return [] if unmatched_ids.empty?

      transfer_match_candidates(
        date_window: TRANSFER_HINT_DATE_WINDOW,
        exchange_rate_tolerance: TRANSFER_HINT_EXCHANGE_RATE_TOLERANCE,
        transaction_ids: unmatched_ids
      )
        .joins("JOIN transactions inflow_txns ON inflow_txns.id = inflow_candidates.entryable_id")
        .joins("JOIN transactions outflow_txns ON outflow_txns.id = outflow_candidates.entryable_id")
        .where(rejected_transfers: { id: nil })
        .where(inflow_candidates: { excluded: false }, outflow_candidates: { excluded: false })
        .where(inflow_txns: { fee_transfer_id: nil }, outflow_txns: { fee_transfer_id: nil })
        .where("inflow_txns.category_id IS NOT DISTINCT FROM outflow_txns.category_id")
        .to_a
    end

    # Only plain transactions are auto-matched: not excluded, not pending at the provider, and
    # still "standard" (a user's one-time mark, or any other kind, is left alone).
    def auto_match_candidates(account: nil)
      transfer_match_candidates(account_id: account&.id, restrict_cross_currency_to_routes: true)
        .joins("JOIN transactions inflow_txns ON inflow_txns.id = inflow_candidates.entryable_id")
        .joins("JOIN transactions outflow_txns ON outflow_txns.id = outflow_candidates.entryable_id")
        .where(rejected_transfers: { id: nil })
        .where(inflow_candidates: { excluded: false }, outflow_candidates: { excluded: false })
        .where(inflow_txns: { kind: "standard" }, outflow_txns: { kind: "standard" })
        # A transfer's linked fee is an expense of that transfer, never a leg of another
        .where(inflow_txns: { fee_transfer_id: nil }, outflow_txns: { fee_transfer_id: nil })
        .where.not(pending_condition("inflow_txns"))
        .where.not(pending_condition("outflow_txns"))
    end

    # Same currency: exactly opposite amounts. Different currencies: the inflow within
    # :min_ratio..:max_ratio of the converted outflow, and with restrict_cross_currency_to_routes
    # only on a known route or between two linked accounts. Binds :family_currency,
    # :min_ratio and :max_ratio.
    def transfer_amounts_match_sql(restrict_cross_currency_to_routes:)
      route_condition = "AND (#{confirmed_route_sql} OR (#{linked_account_sql('inflow_accounts')} AND #{linked_account_sql('outflow_accounts')}))" if restrict_cross_currency_to_routes

      <<~SQL.squish
        (
          inflow_candidates.currency = outflow_candidates.currency AND
          inflow_candidates.amount = -outflow_candidates.amount
        ) OR (
          inflow_candidates.currency <> outflow_candidates.currency AND
          ABS(inflow_candidates.amount / NULLIF(outflow_candidates.amount * #{transfer_match_rate_sql}, 0))
            BETWEEN :min_ratio AND :max_ratio
          #{route_condition}
        )
      SQL
    end

    # The rate that converts the outflow's currency into the inflow's on the outflow's date:
    # the direct pair, else the cross rate through the family currency (bind :family_currency).
    # NULL with neither.
    def transfer_match_rate_sql
      direct = ExchangeRate.rate_sql(from: "outflow_candidates.currency", to: "inflow_candidates.currency", on: "outflow_candidates.date")
      outflow_to_family = ExchangeRate.rate_sql(from: "outflow_candidates.currency", to: ":family_currency", on: "outflow_candidates.date")
      inflow_to_family = ExchangeRate.rate_sql(from: "inflow_candidates.currency", to: ":family_currency", on: "outflow_candidates.date")

      "COALESCE(#{direct}, #{outflow_to_family} / NULLIF(#{inflow_to_family}, 0))"
    end

    # The user confirmed a transfer from this outflow account into this inflow account before
    def confirmed_route_sql
      <<~SQL.squish
        EXISTS (
          SELECT 1 FROM transfers confirmed_transfers
          JOIN entries route_outflows ON route_outflows.entryable_type = 'Transaction'
            AND route_outflows.entryable_id = confirmed_transfers.outflow_transaction_id
          JOIN entries route_inflows ON route_inflows.entryable_type = 'Transaction'
            AND route_inflows.entryable_id = confirmed_transfers.inflow_transaction_id
          WHERE confirmed_transfers.status = 'confirmed'
            AND route_outflows.account_id = outflow_candidates.account_id
            AND route_inflows.account_id = inflow_candidates.account_id
        )
      SQL
    end

    # Account#linked? in SQL: a provider connection or a Plaid account
    def linked_account_sql(accounts_alias)
      <<~SQL.squish
        (#{accounts_alias}.plaid_account_id IS NOT NULL OR
          EXISTS (SELECT 1 FROM account_providers WHERE account_providers.account_id = #{accounts_alias}.id))
      SQL
    end

    def pending_condition(table)
      <<~SQL.squish
        EXISTS (
          SELECT 1 FROM jsonb_each(CASE WHEN jsonb_typeof(#{table}.extra) = 'object' THEN #{table}.extra ELSE '{}'::jsonb END) AS pd
          WHERE jsonb_typeof(pd.value) = 'object' AND (pd.value ->> 'pending')::boolean = true
        )
      SQL
    end

    def create_auto_matched_transfer(match)
      Transfer.transaction(requires_new: true) do
        Transfer.create!(
          inflow_transaction_id: match.inflow_transaction_id,
          outflow_transaction_id: match.outflow_transaction_id
        )
      end
      true
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      Rails.logger.info("Skipped auto-matching transfer #{match.outflow_transaction_id} -> #{match.inflow_transaction_id}: #{e.message}")
      false
    end
end
