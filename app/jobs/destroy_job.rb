class DestroyJob < ApplicationJob
  queue_as :low_priority

  ATTEMPTS = 5

  # A deadlock (for example with a sync that writes to the same account) is transient, so
  # the job runs again with growing waits (about 3 s, 18 s, 83 s, 258 s), which lets a
  # long sync finish first. The record stays pending deletion during the retries. When the
  # attempts run out, the job handles the deadlock like any other failure.
  retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: ATTEMPTS do |job, error|
    job.send(:handle_failure, job.arguments.first, error)
  end

  def perform(model)
    # The stale work reaper restored the account because this job did not run in time;
    # deleting it now would surprise whoever sees it back in their list
    return if model.respond_to?(:pending_deletion?) && !model.pending_deletion?

    model.destroy || raise(ActiveRecord::RecordNotDestroyed.new("#{model.class.name} #{model.try(:id)} was not destroyed", model))
  rescue ActiveRecord::Deadlocked => e
    # The rollback kept the row, so retry_on runs the job again. When the row is already
    # gone (a deadlock in an after-commit step), a retry could not load the record and
    # would be discarded, so record the failure now.
    gone?(model) ? handle_failure(model, e) : raise
  rescue => e
    handle_failure(model, e)
  end

  private
    def handle_failure(model, error)
      report_failure(model, error)
    ensure
      recover(model) unless gone?(model)
    end

    # Puts the record back in a state the user can act on, so a failed deletion is never
    # stuck "in progress". Accounts restore themselves (AASM, to disabled); provider items
    # clear the flag. update_column skips validations: a validation that depends on the
    # flag must not raise here and send the job into Sidekiq retries.
    def recover(model)
      if model.respond_to?(:recover_from_failed_destroy!)
        model.recover_from_failed_destroy!
      elsif model.respond_to?(:has_attribute?) && model.has_attribute?(:scheduled_for_deletion)
        model.reload.update_column(:scheduled_for_deletion, false)
      end
    rescue => e
      report_failure(model, e)
    end

    # Apart from deadlocks, a failed destroy ends the job instead of retrying, so this is
    # the only trace of why the record is still there.
    def report_failure(model, error)
      Rails.logger.error("DestroyJob failed for #{model.class.name} #{model.try(:id)}: #{error.class}: #{error.message}")
      Sentry.capture_exception(error) { |scope| scope.set_tags(record_type: model.class.name, record_id: model.try(:id)) } if defined?(Sentry)

      DebugLogEntry.capture(
        category: "destroy",
        level: "error",
        message: "Could not delete #{model.class.name} #{model.try(:id)}: #{error.class}",
        source: self.class.name,
        **log_context(model),
        metadata: {
          record_type: model.class.name,
          record_id: model.try(:id),
          error_class: error.class.name,
          error_message: error.message.to_s.truncate(500),
          attempts: executions,
          # Why a callback halted the destroy, for RecordNotDestroyed
          record_errors: error.try(:record).try(:errors)&.full_messages.presence,
          backtrace: error.backtrace&.first(5)
        }
      )
    end

    def gone?(record)
      record.respond_to?(:destroyed?) && record.destroyed?
    end

    # An error raised after the delete committed (an after_commit callback) leaves no row
    # to link, and the account_id foreign key would reject the entry.
    def log_context(model)
      case model
      when Account
        gone?(model) ? { family_id: model.family_id } : { account: model }
      when Family
        gone?(model) ? {} : { family: model }
      else
        family = model.try(:family)
        family.is_a?(Family) && !gone?(family) ? { family: family } : {}
      end
    end
end
