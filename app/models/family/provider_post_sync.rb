# The family-wide steps after a bank connection synced on its own (a "Sync now" on the
# connection, or the hourly sync), which a family sync would otherwise run: transfer
# suggestions, rules, subscription charge reconciliation and pattern detection. A
# provider item syncer calls it only when its sync has no parent; a family sync runs
# these itself.
class Family::ProviderPostSync
  attr_reader :family

  def initialize(family)
    @family = family
  end

  def run
    family.auto_match_transfers!

    if family.rules.where(active: true).exists?
      ApplyRulesJob.perform_later(family, execution_type: "scheduled")
    end

    RecurringTransaction.reconcile_charges_for(family)
    RecurringTransaction.identify_patterns_for(family)
  end
end
