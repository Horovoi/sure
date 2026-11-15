# Finds the real charge of each subscription charge the app generated
# (GenerateSubscriptionTransactionsJob) and makes sure the money counts once
# (owner answer 4, tiered):
#
# * Clear match: the generated charge has exactly one candidate, of the same
#   service, within AMOUNT_TOLERANCE of its amount and CLEAR_MATCH_DAYS of its
#   date, and that candidate is no candidate of another generated charge. The
#   real charge replaces the generated one (Transaction#replace_subscription_charge!).
# * Possible match: the same service within POSSIBLE_MATCH_DAYS and
#   POSSIBLE_AMOUNT_TOLERANCE, the same amount within CLEAR_MATCH_DAYS with no
#   service match, or more than one clear candidate. The generated charge is
#   flagged for a one-click merge (reason "subscription_charge").
#
# A candidate is a transaction on the same account, not generated, not linked
# to a recurring row, not a transfer, with an amount of the same sign. Amounts
# are compared in the generated charge's currency (nearest-rate rule).
#
# dry_run: true returns the proposed pairs and writes nothing.
class RecurringTransaction::Reconciler
  LOOKBACK_DAYS = 90
  AMOUNT_TOLERANCE = RecurringTransaction::AMOUNT_TOLERANCE.to_d
  CLEAR_MATCH_DAYS = 5
  POSSIBLE_MATCH_DAYS = 10
  POSSIBLE_AMOUNT_TOLERANCE = "0.5".to_d

  # One proposed pair. action is :replace or :flag.
  Proposal = Data.define(:action, :generated_entry, :real_entry)

  Result = Data.define(:replaced, :flagged) do
    def proposals
      replaced + flagged
    end
  end

  Candidate = Data.define(:entry, :clear, :days, :ratio)

  attr_reader :family

  def initialize(family, dry_run: false)
    @family = family
    @dry_run = dry_run
  end

  def dry_run?
    @dry_run
  end

  def reconcile
    generated = generated_entries
    return Result.new(replaced: [], flagged: []) if generated.empty?

    pool = candidate_pool(generated)
    candidates_by_generated = generated.to_h { |entry| [ entry, candidates_for(entry, pool) ] }

    # How many generated charges each real charge is a candidate for
    claims = Hash.new(0)
    candidates_by_generated.each_value { |candidates| candidates.each { |candidate| claims[candidate.entry.id] += 1 } }

    proposals = candidates_by_generated.filter_map do |generated_entry, candidates|
      next if candidates.empty?

      only = candidates.first
      if candidates.size == 1 && only.clear && claims[only.entry.id] == 1
        Proposal.new(action: :replace, generated_entry: generated_entry, real_entry: only.entry)
      else
        best = candidates.min_by { |candidate| [ candidate.clear ? 0 : 1, candidate.days, candidate.ratio ] }
        Proposal.new(action: :flag, generated_entry: generated_entry, real_entry: best.entry)
      end
    end

    replaced, flagged = proposals.partition { |proposal| proposal.action == :replace }
    return Result.new(replaced: replaced, flagged: flagged) if dry_run?

    Result.new(
      replaced: replaced.select { |proposal| replace!(proposal) },
      flagged: flagged.select { |proposal| flag!(proposal) }
    )
  end

  private
    # Generated charges of the last LOOKBACK_DAYS that are not flagged yet. A
    # flagged charge, also one whose flag was dismissed, is left alone.
    def generated_entries
      family.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(source: "subscription")
        .where.not(transactions: { recurring_transaction_id: nil })
        .where(date: LOOKBACK_DAYS.days.ago.to_date..Date.current)
        .where("transactions.extra -> 'potential_posted_match' IS NULL")
        .includes(:account, entryable: [ :merchant, { recurring_transaction: [ :merchant, :subscription_service ] } ])
        .order(:date, :created_at)
        .to_a
    end

    # Every transaction that can be a real charge of one of the generated ones,
    # by account, in one query
    def candidate_pool(generated)
      first_date, last_date = generated.map(&:date).minmax

      family.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(account_id: generated.map(&:account_id).uniq)
        .where("entries.source IS DISTINCT FROM 'subscription'")
        .where(transactions: { recurring_transaction_id: nil })
        .where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
        .where.not(amount: 0)
        # A provider's pending hold is not the real charge yet: it may be released, or
        # settle under another id, and the generated charge would be lost with it
        .where.not(Transaction.pending_sql("transactions"))
        .where(date: (first_date - POSSIBLE_MATCH_DAYS)..(last_date + POSSIBLE_MATCH_DAYS))
        .includes(entryable: :merchant)
        .to_a
        .group_by(&:account_id)
    end

    def candidates_for(generated_entry, pool)
      recurring = generated_entry.entryable.recurring_transaction
      return [] if recurring.nil? || generated_entry.amount.zero?

      pool.fetch(generated_entry.account_id, []).filter_map do |entry|
        next unless entry.amount.positive? == generated_entry.amount.positive?

        amount = comparable_amount(entry, generated_entry)
        next if amount.nil?

        ratio = ((amount - generated_entry.amount).abs / generated_entry.amount.abs).to_d
        days = (entry.date - generated_entry.date).to_i.abs
        service = same_service?(recurring, generated_entry, entry)

        clear = service && ratio <= AMOUNT_TOLERANCE && days <= CLEAR_MATCH_DAYS
        possible = clear ||
          (service && ratio <= POSSIBLE_AMOUNT_TOLERANCE && days <= POSSIBLE_MATCH_DAYS) ||
          (!service && amount.round(2) == generated_entry.amount.round(2) && days <= CLEAR_MATCH_DAYS)

        Candidate.new(entry: entry, clear: clear, days: days, ratio: ratio) if possible
      end
    end

    # The candidate's amount in the generated charge's currency, or nil when no
    # rate converts it
    def comparable_amount(entry, generated_entry)
      return entry.amount if entry.currency == generated_entry.currency

      ExchangeRate.convert_or_leave_out(
        entry.amount_money, to: generated_entry.currency, date: entry.date,
        source: "RecurringTransaction::Reconciler", family: family
      )&.amount
    end

    # The same merchant, or a name that contains the subscription's display
    # name or its service's name
    def same_service?(recurring, generated_entry, entry)
      transaction = entry.entryable
      merchant_ids = [ recurring.merchant_id, generated_entry.entryable.merchant_id ].compact
      return true if transaction.merchant_id.present? && merchant_ids.include?(transaction.merchant_id)

      names = [ entry.name, transaction.merchant&.name ].compact_blank
      service_names = [ recurring.display_name, recurring.subscription_service&.name ].compact_blank.uniq

      names.any? do |name|
        service_names.any? { |service_name| RecurringTransaction::SubscriptionDetector.name_contains_service_name?(name, service_name) }
      end
    end

    def replace!(proposal)
      proposal.real_entry.entryable.replace_subscription_charge!(proposal.generated_entry, source: self.class.name)
    rescue ActiveRecord::ActiveRecordError => e
      DebugLogEntry.capture(
        category: "recurring_reconcile", level: "error", source: self.class.name, family: family,
        message: "Could not replace the generated charge #{proposal.generated_entry.id} with #{proposal.real_entry.id}: #{e.class}: #{e.message}"
      )
      false
    end

    def flag!(proposal)
      proposal.generated_entry.entryable.flag_potential_duplicate!(
        posted_entry: proposal.real_entry,
        reason: Transaction::SUBSCRIPTION_CHARGE_REASON,
        posted_amount: proposal.real_entry.amount
      )
    rescue ActiveRecord::ActiveRecordError => e
      DebugLogEntry.capture(
        category: "recurring_reconcile", level: "error", source: self.class.name, family: family,
        message: "Could not flag the generated charge #{proposal.generated_entry.id}: #{e.class}: #{e.message}"
      )
      false
    end
end
