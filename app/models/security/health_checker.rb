# The health checker periodically asks the price provider whether it still knows each
# security, and moves the security between the price statuses in Security:
# - found: back to "online" and the failure counter resets
# - the provider says it does not know the symbol, or has no bar in the last
#   LOOKBACK days: one failed check ("degraded"); after more than
#   MAX_CONSECUTIVE_FAILURES in a row, "unavailable" (no longer fetched; price
#   history is kept and the security is still rechecked)
# - no provider configured, rate limits, outages and other errors: inconclusive,
#   nothing changes and the security is checked again on the next run
#
# "manual" securities (entered by the user, unknown to the provider) are never checked.
#
# The health checker is run daily through SecurityHealthCheckJob (see config/schedule.yml), but not all
# securities will be checked every day (we run in batches)
class Security::HealthChecker
  MAX_CONSECUTIVE_FAILURES = 5
  HEALTH_CHECK_INTERVAL = 7.days
  DAILY_BATCH_SIZE = 1000

  # Look for the latest available daily bar rather than today's, which does not exist
  # yet when the job runs (02:00 UTC) and never exists on weekends and holidays.
  LOOKBACK = 14.days

  class << self
    def check_all
      unless Security.provider
        Rails.logger.warn("No securities provider configured, skipping security health checks")
        return
      end

      # No daily limit for unchecked securities (they are prioritized)
      never_checked_scope.find_each do |security|
        new(security).run_check
      end

      # Daily limit for checked securities
      due_for_check_scope.limit(DAILY_BATCH_SIZE).each do |security|
        new(security).run_check
      end
    end

    private
      def checkable_scope
        Security.where.not(status: "manual")
      end

      # If a security has never had a health check, we prioritize it, regardless of batch size
      def never_checked_scope
        checkable_scope.where(last_health_check_at: nil)
      end

      # Any securities not checked for HEALTH_CHECK_INTERVAL are due
      # We only process the batch size, which means some "due" securities will not be checked today
      # This is by design, to prevent all securities from coming due at the same time
      def due_for_check_scope
        checkable_scope.where(last_health_check_at: ..HEALTH_CHECK_INTERVAL.ago)
                       .order(last_health_check_at: :asc)
      end
  end

  def initialize(security)
    @security = security
  end

  def run_check
    return if security.manual?
    return unless provider.present?

    Rails.logger.info("Running health check for #{security.ticker}")

    case check_result
    when :found
      security.last_health_check_at = Time.current
      security.record_health_check_success!
    when :not_found
      security.last_health_check_at = Time.current
      security.record_health_check_failure!
    else
      # Inconclusive: leave the security as it is and check it again on the next run
      Rails.logger.warn("Inconclusive health check for #{security.ticker}, will retry")
    end
  rescue => e
    # Unexpected errors are inconclusive too: not counted, and retried on the next run
    Sentry.capture_exception(e) do |scope|
      scope.set_tags(security_id: @security.id)
    end
  end

  private
    attr_reader :security

    def provider
      Security.provider
    end

    # :found, :not_found or :inconclusive
    def check_result
      response = provider.fetch_security_prices(
        symbol: security.ticker,
        exchange_operating_mic: security.exchange_operating_mic,
        start_date: LOOKBACK.ago.to_date,
        end_date: Date.current
      )

      if response.success?
        response.data.any? { |price| price.price.to_f > 0 } ? :found : :not_found
      elsif response.error.is_a?(Provider::SecurityConcept::SecurityNotFound)
        :not_found
      else
        :inconclusive
      end
    end
end
