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

    # One job runs every active rule in order (Rule::Runner), so two rules that set
    # the same field give the same result on every sync.
    if family.rules.where(active: true).exists?
      Rails.logger.info("Applying rules for family #{family.id}")
      ApplyRulesJob.perform_later(family, execution_type: "scheduled")
    end
  end

  private
    # Only visible (active or draft) accounts: disabled ones are hidden from every total,
    # and accounts pending deletion must not be rebuilt while they are destroyed.
    # Accounts an enabled bank connection syncs are left to its items; every other
    # account (manual, or linked to a provider that is off) syncs here.
    def child_syncables
      syncables = family.accounts.visible.outside_enabled_providers.to_a

      items = BankConnections.item_associations(enabled_only: true).flat_map { |association| family.public_send(association).active.to_a }
      items + syncables
    end
end
