# Runs RecurringTransaction::Reconciler for one family after a sync or an
# import. Debounced like IdentifyRecurringTransactionsJob: when it is
# scheduled several times within DEBOUNCE_DELAY, only the last job runs.
#
# One run per family at a time: the run holds the transaction-level advisory
# lock "recurring_reconcile:<family_id>", and a job that finds it held exits.
# It runs whether or not recurring_transactions_disabled is set, because charge
# generation does not check that switch either.
class RecurringTransaction::ReconcileJob < ApplicationJob
  queue_as :default

  DEBOUNCE_DELAY = 30.seconds

  # How long the "latest scheduled" marker lives. It must outlive any queue
  # latency, or every queued job would run once it expires.
  DEBOUNCE_KEY_TTL = 6.hours

  def self.schedule_for(family)
    scheduled_at = Time.current.to_f
    Rails.cache.write(debounce_key(family.id), scheduled_at, expires_in: DEBOUNCE_KEY_TTL)

    set(wait: DEBOUNCE_DELAY).perform_later(family.id, scheduled_at)
  end

  def self.debounce_key(family_id)
    "recurring_reconcile_scheduled:#{family_id}"
  end

  def self.lock_name(family_id)
    "recurring_reconcile:#{family_id}"
  end

  # scheduled_at nil runs at once (a manual run); otherwise a newer schedule wins
  def perform(family_id, scheduled_at = nil)
    family = Family.find_by(id: family_id)
    return unless family

    if scheduled_at
      latest_scheduled = Rails.cache.read(self.class.debounce_key(family_id))
      return if latest_scheduled && latest_scheduled > scheduled_at
    end

    ActiveRecord::Base.transaction do
      next unless try_advisory_xact_lock(self.class.lock_name(family_id))

      RecurringTransaction::Reconciler.new(family).reconcile
    end
  end

  private
    # The first argument is the family's id
    def family_for_time_zone
      Family.find_by(id: arguments.first)
    end

    # Released when the surrounding transaction ends
    def try_advisory_xact_lock(name)
      key = Digest::MD5.hexdigest(name).to_i(16) % (2**31)
      ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_xact_lock(?)", key ])
      )
    end
end
