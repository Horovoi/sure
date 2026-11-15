# Request pacing for a provider client whose API allows one request per interval
# (per credential, per endpoint). It never sleeps: a caller that finds the slot
# taken gets SlotBusy with the time the slot frees up, and schedules a job for
# then. Sync jobs and web requests are never held open waiting for a slot.
#
# The slots live in Postgres (ProviderRateLimitSlot), so every process and
# thread shares them, and the test environment (null cache store) sees them too.
#
# The including class defines:
# - PROVIDER_ENV_PREFIX (String), e.g. "MONOBANK". The ENV key
#   "#{PROVIDER_ENV_PREFIX}_MIN_REQUEST_INTERVAL" overrides the interval, and the
#   downcased prefix is the slot's provider key.
# - MIN_REQUEST_INTERVAL (Float), the default seconds between two requests.
# - #rate_limit_scope_key (String): what the limit applies to, for example a
#   digest of the access token. Never the token itself.
#
# Example:
#
#   class Provider::Monobank < Provider
#     include Provider::RateLimitable
#     PROVIDER_ENV_PREFIX = "MONOBANK"
#     MIN_REQUEST_INTERVAL = 60.0
#
#     def get_client_info
#       reserve_request_slot!(:client_info) # raises SlotBusy when taken
#       # ... one HTTP request ...
#     end
#   end
module Provider::RateLimitable
  extend ActiveSupport::Concern

  # The slot for this bucket is taken until retry_at
  class SlotBusy < StandardError
    attr_reader :retry_at, :bucket

    def initialize(bucket:, retry_at:)
      @bucket = bucket.to_sym
      @retry_at = retry_at
      super("#{bucket} request slot busy until #{retry_at.iso8601}")
    end
  end

  # Seconds between two requests in one bucket. A configured value that does not
  # parse, or is not positive, must not silently turn pacing off ("invalid".to_f
  # is 0), so it is an error.
  def min_request_interval
    key = "#{provider_env_prefix}_MIN_REQUEST_INTERVAL"
    value = ENV.fetch(key, self.class::MIN_REQUEST_INTERVAL)
    interval = Float(value, exception: false)
    if interval.nil? || !interval.finite? || interval <= 0
      raise ArgumentError, "#{key} must be a positive number of seconds, got #{value.inspect}"
    end

    interval
  end

  # Takes the slot for one request now. Returns the time the next request in this
  # bucket may go, or raises SlotBusy (nothing is reserved then). Atomic across
  # processes: of two concurrent callers exactly one gets the slot.
  def reserve_request_slot!(bucket)
    reserved, next_free_at = ProviderRateLimitSlot.reserve(**slot_key(bucket), interval: min_request_interval)
    raise SlotBusy.new(bucket: bucket, retry_at: next_free_at) unless reserved

    next_free_at
  end

  # Pushes the bucket's next free time to until_time (never earlier than it is),
  # for example after the API answered 429.
  def defer_request_slot!(bucket, until_time)
    ProviderRateLimitSlot.defer(**slot_key(bucket), until_time: until_time)
  end

  # When the next request in this bucket may go (now or earlier when it is free)
  def next_request_slot_at(bucket)
    ProviderRateLimitSlot.next_free_at(**slot_key(bucket))
  end

  private
    def provider_env_prefix
      self.class::PROVIDER_ENV_PREFIX
    end

    def rate_limit_provider_key
      provider_env_prefix.downcase
    end

    def slot_key(bucket)
      { provider_key: rate_limit_provider_key, scope_key: rate_limit_scope_key.to_s, bucket: bucket.to_s }
    end
end
