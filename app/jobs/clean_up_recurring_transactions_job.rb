# Daily stale detection for recurring transactions: marks patterns that
# stopped occurring as inactive (so they stop projecting entries) and
# removes detected patterns that have been inactive for 6+ months.
class CleanUpRecurringTransactionsJob < ApplicationJob
  queue_as :scheduled

  def perform
    Family.find_each do |family|
      next if family.recurring_transactions_disabled?

      cleaner = RecurringTransaction::Cleaner.new(family)
      stale, removed = in_time_zone_of(family) do
        [ cleaner.cleanup_stale_transactions, cleaner.remove_old_inactive_transactions.size ]
      end

      if stale.positive? || removed.positive?
        Rails.logger.info("CleanUpRecurringTransactionsJob: family #{family.id}: #{stale} marked stale, #{removed} removed")
      end
    rescue => e
      Rails.logger.error("CleanUpRecurringTransactionsJob failed for family #{family.id}: #{e.class}: #{e.message}")
    end
  end
end
