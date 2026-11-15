# Moves work whose job was lost (a crash, a deploy, the Mac asleep) from an in-progress
# state to a final one, so nothing waits forever and the UI offers retry or delete.
# Scheduled hourly (config/schedule.yml).
#
# Each model owns its own definition of "stale" (a scope) and its terminal transition;
# this job only drives them. A rule marked quiet: true is counted but not written to the
# debug log, for work whose normal end is to time out. Syncs are handled first because they also finalize parents.
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
    },
    # goal-pledges: a pledge nothing kept within its window expires. In place of
    # upstream's 15-minute sweep job; hourly is soon enough for a 7-day window. Quiet:
    # an expiry is the normal end of a pledge, not lost work for the debug log.
    "GoalPledge" => {
      stale: -> { GoalPledge.stale },
      reap: ->(pledge) { pledge.expire! if pledge.may_expire? },
      quiet: true
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
        before = nil
        reaped = record.with_lock do
          before = record.status
          rule[:reap].call(record)
          record.status != before
        end
        if reaped
          count += 1
          capture_reap(name, record, before) unless rule[:quiet]
        end
      rescue AASM::InvalidTransition
        # Its job finished between the query and the transition: nothing to do
      rescue => e
        Rails.logger.error("[StaleWorkReaper] #{name} #{record.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e)
      end

      count
    end

    # Each reap is a warn entry in Settings > Debug: the work's job was lost somewhere
    def capture_reap(name, record, before)
      DebugLogEntry.capture(
        category: "stale_work",
        level: "warn",
        message: "#{name} #{record.id} reaped: was #{before}, now #{record.status}",
        source: self.class.name,
        family: family_of(record),
        account: record.is_a?(Account) ? record : nil,
        metadata: { record_type: name, record_id: record.id, status: record.status, created_at: record.try(:created_at)&.iso8601 }
      )
    end

    def family_of(record)
      return record if record.is_a?(Family)

      record.try(:family) ||
        record.try(:rule)&.family ||
        record.try(:chat)&.user&.family ||
        record.try(:impersonated)&.family
    rescue StandardError
      nil
    end
end
