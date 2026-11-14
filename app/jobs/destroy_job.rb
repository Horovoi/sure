class DestroyJob < ApplicationJob
  queue_as :low_priority

  def perform(model)
    # The stale work reaper restored the account because this job did not run in time;
    # deleting it now would surprise whoever sees it back in their list
    return if model.respond_to?(:pending_deletion?) && !model.pending_deletion?

    model.destroy || raise(ActiveRecord::RecordNotDestroyed.new("destroy was halted by a callback", model))
  rescue => e
    Rails.logger.error("DestroyJob: could not destroy #{model.class.name} #{model.id}: #{e.class}: #{e.message}")
    Sentry.capture_exception(e)
    recover(model)
  end

  private
    # Puts the record back in a state the user can act on, so a failed deletion is never
    # stuck "in progress". Accounts restore themselves (AASM); provider items clear the flag.
    def recover(model)
      if model.respond_to?(:recover_from_failed_destroy!)
        model.recover_from_failed_destroy!
      elsif model.has_attribute?(:scheduled_for_deletion)
        model.reload.update_column(:scheduled_for_deletion, false)
      end
    rescue => e
      Rails.logger.error("DestroyJob: could not recover #{model.class.name} #{model.id}: #{e.message}")
      Sentry.capture_exception(e)
    end
end
