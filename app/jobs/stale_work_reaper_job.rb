# Moves work whose job was lost (a crash, a deploy, the Mac asleep) from an in-progress
# state to a final one, so nothing waits forever and the UI offers retry or delete.
# Scheduled every 15 minutes (config/schedule.yml).
class StaleWorkReaperJob < ApplicationJob
  queue_as :scheduled

  # model: AASM model, states: in-progress states, after: age of updated_at that counts
  # as lost, event: terminal AASM event to fire (must be allowed from each state).
  RULES = [
    { model: "FamilyExport", states: %w[pending processing], after: -> { FamilyExport::STALE_AFTER }, event: :fail }
  ].freeze

  def perform
    reaped = { "Sync" => Sync.clean }

    RULES.each do |rule|
      reaped[rule[:model]] = reap(rule)
    end

    reaped.select! { |_, count| count.positive? }
    Rails.logger.info("[StaleWorkReaper] #{reaped.presence || 'nothing stale'}")
    reaped
  end

  private
    def reap(rule)
      model = rule[:model].constantize
      cutoff = rule[:after].call.ago
      count = 0

      model.where(status: rule[:states]).where("#{model.table_name}.updated_at < ?", cutoff).find_each do |record|
        record.with_lock do
          next unless rule[:states].include?(record.status) && record.public_send("may_#{rule[:event]}?")
          record.public_send("#{rule[:event]}!")
          count += 1
        end
      rescue => e
        Rails.logger.error("[StaleWorkReaper] #{rule[:model]} #{record.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e)
      end

      count
    end
end
