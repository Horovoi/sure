require "sidekiq/web"

if Rails.env.production?
  Sidekiq::Web.use(Rack::Auth::Basic) do |username, password|
    configured_username = ::Digest::SHA256.hexdigest(ENV.fetch("SIDEKIQ_WEB_USERNAME", "sure"))
    configured_password = ::Digest::SHA256.hexdigest(ENV.fetch("SIDEKIQ_WEB_PASSWORD", "sure"))

    ActiveSupport::SecurityUtils.secure_compare(::Digest::SHA256.hexdigest(username), configured_username) &&
      ActiveSupport::SecurityUtils.secure_compare(::Digest::SHA256.hexdigest(password), configured_password)
  end
end

# Configure Redis connection for Sidekiq
# Supports both Redis Sentinel (for HA) and direct Redis URL
redis_config = if ENV["REDIS_SENTINEL_HOSTS"].present?
  # Redis Sentinel configuration for high availability
  # REDIS_SENTINEL_HOSTS should be comma-separated list: "host1:port1,host2:port2,host3:port3"
  sentinels = ENV["REDIS_SENTINEL_HOSTS"].split(",").filter_map do |host_port|
    parts = host_port.strip.split(":", 2)
    host = parts[0]&.strip
    port_str = parts[1]&.strip

    next if host.blank?

    # Parse port with validation, default to 26379 if invalid or missing
    port = if port_str.present?
      port_int = port_str.to_i
      (port_int > 0 && port_int <= 65535) ? port_int : 26379
    else
      26379
    end

    { host: host, port: port }
  end

  if sentinels.empty?
    Rails.logger.warn("REDIS_SENTINEL_HOSTS is set but no valid sentinel hosts found, falling back to REDIS_URL")
    { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
  else
    {
      url: "redis://#{ENV.fetch('REDIS_SENTINEL_MASTER', 'mymaster')}/0",
      sentinels: sentinels,
      password: ENV["REDIS_PASSWORD"],
      sentinel_username: ENV.fetch("REDIS_SENTINEL_USERNAME", "default"),
      sentinel_password: ENV["REDIS_PASSWORD"],
      role: :master,
      # Recommended timeouts for Sentinel
      connect_timeout: 0.2,
      read_timeout: 1,
      write_timeout: 1,
      reconnect_attempts: 3
    }
  end
else
  # Standard Redis URL configuration (no Sentinel)
  { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end

Sidekiq.configure_server do |config|
  config.redis = redis_config

  # Jobs scheduled from Settings (nightly sync, data cleaner, health checks, subscription
  # transactions) live only in Redis. Rebuild them from the settings on every start, after
  # sidekiq-cron has loaded config/schedule.yml (its startup hook is registered first, when
  # the gem loads), so a lost or stale Redis copy can never silently stop them.
  config.on(:startup) do
    Rails.application.executor.wrap do
      AutoSyncScheduler.sync!
      ScheduledJobsManager.sync!
    rescue => e
      Rails.logger.error("[Sidekiq startup] Could not reconcile scheduled jobs: #{e.class}: #{e.message}")
      Sentry.capture_exception(e)
    end
  end
end

Sidekiq.configure_client do |config|
  config.redis = redis_config
end

Sidekiq::Cron.configure do |config|
  # Catch-up window for a tick missed while the worker was down: a deploy, or the Mac
  # asleep overnight (Docker pauses with it). The most recent missed run of each job is
  # enqueued once when the worker is back; a daily job never runs twice for one day.
  config.reschedule_grace_period = 23.hours.to_i
end
