# Moves work whose job was lost (a crash, a deploy, the Mac asleep) from an in-progress
# state to a final one, so nothing waits forever and the UI offers retry or delete.
# Scheduled hourly (config/schedule.yml).
#
# Each model owns its own definition of "stale" (a scope) and its terminal transition;
# this job only drives them. Syncs are handled first because they also finalize parents.
class StaleWorkReaperJob < ApplicationJob
  queue_as :scheduled

  RULES = {
    "Import" => {
      stale: -> { Import.stale },
      reap: ->(import) { import.mark_stale! if import.may_mark_stale? }
    },
    "RuleRun" => {
      stale: -> { RuleRun.stale },
      reap: ->(run) { run.fail!("Timed out after #{RuleRun::STALE_AFTER.inspect} waiting for its jobs") if run.may_fail? }
    },
    "AssistantMessage" => {
      stale: -> { AssistantMessage.stale },
      reap: ->(turn) { turn.fail_turn(AssistantMessage::StaleTurnError.new("The reply did not finish. Try again.")) }
    },
    "FamilyDocument" => {
      stale: -> { FamilyDocument.stale },
      reap: ->(document) { document.mark_error!("The upload did not finish") if document.may_mark_error? }
    },
    "FamilyExport" => {
      stale: -> { FamilyExport.stale },
      reap: ->(export) { export.fail! if export.may_fail? }
    },
    "ImpersonationSession" => {
      stale: -> { ImpersonationSession.expired },
      reap: ->(impersonation) { impersonation.complete! if impersonation.may_complete? }
    },
    "Account" => {
      stale: -> { Account.stale_deletion },
      reap: ->(account) { account.restore! if account.may_restore? }
    },
    "Eval::Run" => {
      stale: -> { Eval::Run.stale },
      reap: ->(run) { run.fail! if run.may_fail? }
    }
  }.freeze

  def perform
    reaped = { "Sync" => Sync.clean }

    RULES.each do |name, rule|
      reaped[name] = reap(name, rule)
    end

    reaped.select! { |_, count| count.positive? }
    Rails.logger.info("[StaleWorkReaper] #{reaped.presence || 'nothing stale'}")
    reaped
  end

  private
    def reap(name, rule)
      count = 0

      rule[:stale].call.find_each do |record|
        # The row lock reloads the record, so work that finished since the query is left alone
        reaped = record.with_lock do
          before = record.status
          rule[:reap].call(record)
          record.status != before
        end
        count += 1 if reaped
      rescue AASM::InvalidTransition
        # Its job finished between the query and the transition: nothing to do
      rescue => e
        Rails.logger.error("[StaleWorkReaper] #{name} #{record.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e)
      end

      count
    end
end
