# Removes a provider's pending holds that the provider no longer reports (the hold was
# released, or it settled under a new id), so they stop counting.
#
# A hold the user attached something to (notes, tags, files, a goal, a transfer, a
# subscription link, an import or a provider claim) is never destroyed: it is released
# instead. It keeps its pending flag and gets extra[source]["hold_released_at"], so it
# counts nowhere (not in reports, not in any balance, see Transaction.released_hold_sql)
# and stays visible with what the user attached. The user can delete it. A category or a
# name the user set alone does not keep a hold: the bank never charged it.
#
#   Account::ProviderPendingPruner.new(account, source: "monobank")
#     .prune!(keep_external_ids: ids_in_the_latest_statement)
#   # => { pruned: 2, detached: 1 }
class Account::ProviderPendingPruner
  def initialize(account, source:)
    @account = account
    @source = source.to_s
  end

  def prune!(keep_external_ids:)
    keep = Array(keep_external_ids).map(&:to_s)
    pruned = 0
    detached = 0

    stale_entries(keep).each do |entry|
      if protected?(entry)
        release!(entry)
        detached += 1
      else
        entry.destroy!
        pruned += 1
      end
    end

    log_detached(detached) if detached.positive?

    { pruned: pruned, detached: detached }
  end

  # Whether the user (or another part of the app) attached something to this entry
  def protected?(entry)
    transaction = entry.entryable
    extra = transaction.extra.is_a?(Hash) ? transaction.extra : {}

    entry.notes.present? ||
      entry.import_id.present? ||
      extra["goal"].present? ||
      extra["provider_claim"].present? ||
      transaction.recurring_transaction_id.present? ||
      transaction.fee_transfer_id.present? ||
      transaction.transfer_as_inflow.present? ||
      transaction.transfer_as_outflow.present? ||
      transaction.taggings.exists? ||
      transaction.attachments.attached?
  end

  private
    attr_reader :account, :source

    def stale_entries(keep)
      scope = account.entries.pending_from(source).where.not(Transaction.released_hold_sql("transactions")).includes(:entryable)
      scope = scope.where.not(external_id: keep) if keep.any?
      scope.to_a
    end

    def release!(entry)
      transaction = entry.entryable
      extra = (transaction.extra || {}).deep_dup
      provider_data = extra[source].is_a?(Hash) ? extra[source] : {}
      provider_data["hold_released_at"] = Time.current.iso8601
      extra[source] = provider_data

      transaction.update!(extra: extra)
    end

    def log_detached(detached)
      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "Kept #{detached} released #{source} hold(s) the user had attached something to; they no longer count",
        source: self.class.name,
        account: account,
        provider_key: source,
        metadata: { detached: detached }
      )
    end
end
