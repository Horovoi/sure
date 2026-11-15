class BalanceSheet::SyncStatusMonitor
  def initialize(family)
    @family = family
  end

  def syncing?
    syncing_account_ids.any?
  end

  def account_syncing?(account)
    syncing_account_ids.include?(account.id)
  end

  private
    attr_reader :family

    def syncing_account_ids
      # The key changes on every sync commit; the short expiry covers the case where nothing
      # commits (a sync whose job was lost) so the UI stops showing it as syncing.
      # Memoized because every account row of the sidebar asks once per render; each
      # call would otherwise be a cache round-trip (or a full query with the null store).
      @syncing_account_ids ||= Rails.cache.fetch(cache_key, expires_in: 1.minute) do
        Sync.visible
            .where(syncable_type: "Account", syncable_id: family.accounts.visible.pluck(:id))
            .pluck(:syncable_id)
            .to_set
      end
    end

    # We re-fetch the set of syncing IDs any time a sync that belongs to the family is started or completed.
    # This ensures we're always fetching the latest sync statuses without re-querying on every page load in idle times (no syncs happening).
    def cache_key
      [
        "balance_sheet_sync_status",
        family.id,
        family.latest_sync_activity_at
      ].join("_")
    end
end
