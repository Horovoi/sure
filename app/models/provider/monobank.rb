# Client for monobank's personal API (https://api.monobank.ua/docs/).
#
# monobank allows one request per 60 seconds per token per function. This client
# never waits for that: every call makes at most one HTTP request, after it took a
# request slot (Provider::RateLimitable, stored in Postgres so every process shares
# it). When the slot is taken, or monobank answers 429, the call raises
# RateLimitError with the time the next slot is free, and the caller (a job)
# reschedules itself for then. There are no retries and no sleeps.
#
# The token is sent only to https://api.monobank.ua, or to a loopback host when
# MONOBANK_API_BASE_URL points at one (tests and the local fake API).
class Provider::Monobank < Provider
  include HTTParty
  include Provider::RateLimitable
  extend SslConfigurable

  class Error < Provider::Error; end

  class RateLimitError < Error
    attr_reader :retry_at

    def initialize(message = "monobank rate limit", retry_at: nil, details: nil)
      super(message, details: details, failure_code: :rate_limited)
      @retry_at = retry_at
    end
  end

  BASE_URL_ENV = "MONOBANK_API_BASE_URL".freeze
  DEFAULT_BASE_URL = "https://api.monobank.ua".freeze
  LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1 [::1]].freeze

  PROVIDER_ENV_PREFIX = "MONOBANK".freeze
  MIN_REQUEST_INTERVAL = 60.0

  # 31 days + 1 hour, the longest statement window monobank accepts
  MAX_STATEMENT_WINDOW = 2_682_000
  # monobank returns at most this many rows, newest first; a full page may be cut
  MAX_STATEMENT_ITEMS = 500

  REQUEST_TIMEOUT = 30

  NETWORK_ERRORS = [
    SocketError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
    Errno::ETIMEDOUT, Errno::EHOSTUNREACH, EOFError, OpenSSL::SSL::SSLError
  ].freeze

  headers "User-Agent" => "Sure Finance monobank client"
  default_options.merge!({ timeout: REQUEST_TIMEOUT }.merge(httparty_ssl_options))

  attr_reader :access_token, :base_url

  def self.configured_base_url
    ENV[BASE_URL_ENV].presence || DEFAULT_BASE_URL
  end

  def initialize(access_token, base_url: self.class.configured_base_url)
    @access_token = access_token.to_s.strip
    raise Error.new("monobank access token is required", failure_code: :configuration_error) if @access_token.blank?

    @base_url = validated_base_url(base_url)
  end

  # GET /personal/client-info: the client's cards, currency accounts and jars.
  def get_client_info
    payload = request("/personal/client-info", bucket: :client_info)
    raise Error.new("Unexpected monobank client-info response", failure_code: :parse_error) unless payload.is_a?(Hash)

    payload.with_indifferent_access
  end

  # Cards and jars of a client-info payload as one list, each with kind "card" or "jar".
  # Makes no request when client_info is given.
  def get_accounts(client_info: nil)
    payload = (client_info || get_client_info).with_indifferent_access

    cards = Array(payload[:accounts]).filter_map { |account| flatten_account(account, kind: "card") }
    jars = Array(payload[:jars]).filter_map { |jar| flatten_account(jar, kind: "jar") }
    cards + jars
  end

  # GET /personal/statement/{account}/{from}/{to}: at most 500 rows, newest first.
  def get_statement(account_id:, from:, to: nil)
    from_unix = to_unix(from)
    to_unix_value = to.nil? ? Time.current.to_i : to_unix(to)

    raise Error.new("monobank statement window ends before it starts", failure_code: :bad_request) if to_unix_value < from_unix
    if (to_unix_value - from_unix) > MAX_STATEMENT_WINDOW
      raise Error.new("monobank statement window exceeds 31 days and 1 hour", failure_code: :window_too_large)
    end

    path = "/personal/statement/#{ERB::Util.url_encode(account_id.to_s)}/#{from_unix}/#{to_unix_value}"
    rows = request(path, bucket: :statement)
    raise Error.new("Unexpected monobank statement response", failure_code: :parse_error) unless rows.is_a?(Array)

    rows.filter_map do |row|
      next unless row.is_a?(Hash)

      row.with_indifferent_access.merge(account_id: account_id.to_s)
    end
  end

  # Request slots are shared by every client of one token.
  def rate_limit_scope_key
    Digest::SHA256.hexdigest(access_token)[0, 32]
  end

  private
    def request(path, bucket:)
      begin
        reserve_request_slot!(bucket)
      rescue Provider::RateLimitable::SlotBusy => e
        raise RateLimitError.new("monobank request slot for #{bucket} is busy", retry_at: e.retry_at)
      end

      response = begin
        self.class.get("#{base_url}#{path}", headers: auth_headers, timeout: REQUEST_TIMEOUT)
      rescue *NETWORK_ERRORS => e
        raise Error.new("monobank request failed: #{e.class}", failure_code: :network_error)
      end

      handle_response(response, bucket: bucket)
    end

    def handle_response(response, bucket:)
      case response.code
      when 200
        parse_body(response)
      when 400
        raise Error.new("monobank rejected the request: #{error_description(response)}", failure_code: :bad_request)
      when 401
        raise Error.new("monobank token is not valid", failure_code: :unauthorized)
      when 403
        raise Error.new("monobank refused the token", failure_code: :access_forbidden)
      when 404
        raise Error.new("monobank resource not found", failure_code: :not_found)
      when 429
        retry_at = Time.current + min_request_interval
        defer_request_slot!(bucket, retry_at)
        raise RateLimitError.new("monobank rate limit exceeded", retry_at: retry_at)
      when 500..599
        raise Error.new("monobank server error (#{response.code})", failure_code: :server_error)
      else
        raise Error.new("Unexpected monobank response status #{response.code}", failure_code: :fetch_failed)
      end
    end

    def parse_body(response)
      raise Error.new("Empty monobank response", failure_code: :parse_error) if response.body.blank?

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error.new("monobank response is not JSON", failure_code: :parse_error)
    end

    def error_description(response)
      JSON.parse(response.body.to_s)["errorDescription"].to_s.truncate(200)
    rescue JSON::ParserError, TypeError, NoMethodError
      "status #{response.code}"
    end

    def auth_headers
      { "X-Token" => access_token, "Accept" => "application/json" }
    end

    def flatten_account(resource, kind:)
      return nil unless resource.is_a?(Hash)

      data = resource.with_indifferent_access
      return nil if data[:id].blank?

      data.merge(kind: kind)
    end

    # https://api.monobank.ua, or http(s) on a loopback host with any port
    def validated_base_url(value)
      uri = URI.parse(value.to_s.strip.chomp("/"))
      allowed = if uri.host == URI.parse(DEFAULT_BASE_URL).host
        uri.scheme == "https" && [ nil, 443 ].include?(uri.port) && uri.path.blank?
      else
        uri.scheme.in?(%w[http https]) && uri.host.to_s.downcase.in?(LOOPBACK_HOSTS)
      end
      raise Error.new("monobank API URL is not allowed: #{value}", failure_code: :invalid_url) unless allowed && uri.userinfo.nil?

      uri.to_s
    rescue URI::InvalidURIError
      raise Error.new("monobank API URL is not valid", failure_code: :invalid_url)
    end

    # Unix seconds; a bare Date is UTC midnight
    def to_unix(value)
      return value.to_time(:utc).to_i if value.instance_of?(Date)

      case value
      when Integer then value
      when Float then value.to_i
      when Time, DateTime, ActiveSupport::TimeWithZone then value.to_time.to_i
      else
        raise Error.new("Unsupported monobank statement time", failure_code: :bad_request)
      end
    end
end
