# The family-wide steps after a bank connection synced on its own (a "Sync now" on the
# connection, or the hourly sync), which a family sync would otherwise run: transfer
# suggestions, rules, subscription charge reconciliation and pattern detection. A
# provider item syncer calls it only when its sync has no parent; a family sync runs
# these itself.
#
# Rules run over every transaction, and AI rules send each uncategorised one to the
# LLM, so they run only when the sync booked new entries (new_entries: true) and at most
# once per RULES_DEBOUNCE. Entries a skipped run would have seen get the rules on the
# next run, at the latest with the nightly family sync.
class Family::ProviderPostSync
  RULES_DEBOUNCE = 30.minutes

  attr_reader :family

  def initialize(family)
    @family = family
  end

  def run(new_entries: true)
    family.auto_match_transfers!

    ApplyRulesJob.perform_later(family, execution_type: "scheduled") if new_entries && apply_rules?

    RecurringTransaction.reconcile_charges_for(family)
    RecurringTransaction.identify_patterns_for(family)
  end

  private
    def apply_rules?
      rules = family.rules.where(active: true)
      return false unless rules.exists?

      !RuleRun.where(rule_id: family.rules.select(:id), execution_type: "scheduled")
              .where(executed_at: RULES_DEBOUNCE.ago..).exists?
    end
end
