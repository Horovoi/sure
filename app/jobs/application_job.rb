class ApplicationJob < ActiveJob::Base
  retry_on ActiveRecord::Deadlocked
  discard_on ActiveJob::DeserializationError
  queue_as :low_priority # default queue

  # A job about one family's data runs in that family's time zone, like its web
  # requests do, so "today" (Date.current) means the same day in both. Without it,
  # jobs ran in UTC and disagreed with the browser for hours after local midnight.
  around_perform do |job, block|
    zone = job.send(:family_time_zone)
    zone ? Time.use_zone(zone, &block) : block.call
  end

  private
    def family_time_zone
      subject = arguments.first
      family = if subject.is_a?(Family)
        subject
      elsif subject.respond_to?(:family)
        subject.family
      end
      family&.timezone.presence
    rescue StandardError
      nil
    end
end
