class RecurringTransaction
  class Cleaner
    attr_reader :family

    def initialize(family)
      @family = family
    end

    # Mark recurring transactions as inactive if they haven't occurred for
    # longer than RecurringTransaction#stale_after.
    # Rows marked here get inactive_reason "stale", so the Identifier can
    # reactivate them when the pattern resumes.
    def cleanup_stale_transactions
      stale_count = 0

      family.recurring_transactions.active.find_each do |recurring_transaction|
        next unless recurring_transaction.should_be_inactive?

        threshold = recurring_transaction.stale_after.ago.to_date

        # Double-check if there are any recent matching transactions
        recent_matches = recurring_transaction.matching_transactions.select { |entry| entry.date >= threshold }

        if recent_matches.empty?
          recurring_transaction.mark_inactive!(reason: "stale")
          stale_count += 1
        end
      end

      stale_count
    end

    # Remove detected patterns that have been inactive for 6+ months.
    # Rows the user created or curated (manual rows, subscriptions),
    # dismissed suggestions (which keep a dismissal from coming back) and
    # patterns the user paused (the Identifier would detect them again as
    # active) are never deleted automatically.
    def remove_old_inactive_transactions
      six_months_ago = 6.months.ago

      family.recurring_transactions
        .inactive
        .pattern
        .where(manual: false)
        .where(inactive_reason: [ nil, "stale" ])
        .where("updated_at < ?", six_months_ago)
        .destroy_all
    end
  end
end
