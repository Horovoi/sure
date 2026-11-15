# Removes a provider's pending holds that the provider no longer reports (the hold was
# released, or it settled under a new id), so they stop counting.
#
# A hold the user did something with is never destroyed: it is detached instead. It
# loses its pending flag, gets extra[source]["hold_released_at"] and stays as an
# ordinary entry, with its notes, tags, attachments, goal link, subscription link,
# transfer and import claim intact. The user can delete it if it was a duplicate.
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
        detach!(entry)
        detached += 1
      else
        entry.destroy!
        pruned += 1
      end
    end

    log_detached(detached) if detached.positive?

    { pruned: pruned, detached: detached }
  end

  # Whether the user (or another part of the app) relies on this entry
  def protected?(entry)
    transaction = entry.entryable
    extra = transaction.extra.is_a?(Hash) ? transaction.extra : {}

    entry.protected_from_sync? ||
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
      scope = account.entries.pending_from(source).includes(:entryable)
      scope = scope.where.not(external_id: keep) if keep.any?
      scope.to_a
    end

    def detach!(entry)
      transaction = entry.entryable
      extra = (transaction.extra || {}).deep_dup
      provider_data = extra[source].is_a?(Hash) ? extra[source] : {}
      provider_data.delete("pending")
      provider_data["hold_released_at"] = Time.current.iso8601
      extra[source] = provider_data

      transaction.update!(extra: extra)
    end

    def log_detached(detached)
      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "Kept #{detached} released #{source} hold(s) the user had changed, as ordinary entries",
        source: self.class.name,
        account: account,
        provider_key: source,
        metadata: { detached: detached }
      )
    end
end
