# Moves work whose job was lost (a crash, a deploy, the Mac asleep) from an in-progress
# state to a final one, so nothing waits forever and the UI offers retry or delete.
# Scheduled every 15 minutes (config/schedule.yml).
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
    "AssistantMessage" => {
      stale: -> { AssistantMessage.stale },
      reap: ->(turn) { turn.fail_turn(AssistantMessage::StaleTurnError.new("The reply did not finish. Try again.")) }
    },
    "FamilyDocument" => {
      stale: -> { FamilyDocument.stale },
      reap: ->(document) { document.mark_error!("The upload did not finish") if document.may_mark_error? }
    },
    "FamilyExport" => {
      stale: -> { FamilyExport.where(status: %w[pending processing]).where(updated_at: ...FamilyExport::STALE_AFTER.ago) },
      reap: ->(export) { export.fail! if export.may_fail? }
    },
    "Eval::Run" => {
      stale: -> { Eval::Run.where(status: "running").where(updated_at: ...24.hours.ago) },
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
        before = record.status
        rule[:reap].call(record)
        count += 1 if record.reload.status != before
      rescue AASM::InvalidTransition
        # Its job finished between the query and the transition: nothing to do
      rescue => e
        Rails.logger.error("[StaleWorkReaper] #{name} #{record.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e)
      end

      count
    end
end
