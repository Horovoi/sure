class Family::Syncer
  attr_reader :family

  def initialize(family)
    @family = family
  end

  def perform_sync(sync)
    # Create every child sync in one transaction. Jobs are enqueued after commit, so no
    # child can start (and finish the parent early) before all of its siblings exist.
    Sync.transaction do
      child_syncables.each do |syncable|
        syncable.sync_later(parent_sync: sync, window_start_date: sync.window_start_date, window_end_date: sync.window_end_date)
      end
    end
  end

  def perform_post_sync
    family.auto_match_transfers!

    Rails.logger.info("Applying rules for family #{family.id}")
    family.rules.where(active: true).each do |rule|
      rule.apply_later
    end
  end

  private
    # Only visible (active or draft) manual accounts: disabled ones are hidden from every
    # total, and accounts pending deletion must not be rebuilt while they are destroyed.
    # Bank-connection items sync only when that feature is switched on.
    def child_syncables
      syncables = family.accounts.visible.manual.to_a
      return syncables unless BankConnections.enabled?

      family.plaid_items.active.to_a + family.lunchflow_items.active.to_a + family.enable_banking_items.active.to_a +
        family.coinstats_items.active.to_a + family.coinbase_items.active.to_a + syncables
    end
end
