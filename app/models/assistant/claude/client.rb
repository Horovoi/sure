# HTTP client for the Claude bridge on the Mac (claude_bridge/server.ts), reached from Docker at
# CLAUDE_BRIDGE_URL with the CLAUDE_BRIDGE_TOKEN bearer.
#
# POST /turn answers with one JSON object per line (NDJSON): session, text, tool, tool_result, rate_limit,
# heartbeat, then result or error. #turn yields each object as a Hash.
#
# - Connect timeout 5 s. Read timeout 45 s: three missed heartbeats (one every 15 s) mean the bridge is gone.
# - One retry, for a refused or reset connection, and only before the first byte arrived: after that the bridge
#   may already have run tools, and a second run would repeat their writes.
# - A line longer than 1 MB is refused, so a broken bridge cannot fill the worker's memory.
class Assistant::Claude::Client
  CONNECT_TIMEOUT = 5
  READ_TIMEOUT = 45
  # /health starts a Claude Code probe the first time (cached 60 s by the bridge), which takes a few seconds
  STATUS_READ_TIMEOUT = 25
  MAX_LINE_BYTES = 1.megabyte
  MAX_ERROR_BODY_BYTES = 64.kilobytes
  RETRYABLE_CONNECT_ERRORS = [ Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EPIPE, Net::OpenTimeout ].freeze
  UNREACHABLE_ERRORS = [ *RETRYABLE_CONNECT_ERRORS, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL,
                         SocketError, IOError, EOFError ].freeze

  def initialize(url:, token:, time_zone: nil)
    @url = URI.parse(url.to_s.chomp("/"))
    @token = token.to_s
    @time_zone = time_zone
  end

  # Runs one turn and yields every event. Raises Assistant::Claude::Error when the bridge cannot be reached, refuses
  # the request or the stream breaks. An "error" event is yielded like any other; the caller raises it.
  def turn(body, &block)
    attempts = 0

    begin
      attempts += 1
      @received_any = false
      post_streaming("/turn", body, &block)
    rescue *RETRYABLE_CONNECT_ERRORS => e
      retry if attempts < 2 && !@received_any
      raise unreachable(e)
    rescue Net::ReadTimeout
      raise Assistant::Claude::Error.new("timeout", time_zone: time_zone)
    rescue *UNREACHABLE_ERRORS => e
      raise unreachable(e)
    end
  end

  # GET /health: the signed-in account, plan, usage windows and bundled Claude Code version
  def health
    get_json("/health")
  end

  # GET /models: the models the signed-in Claude Code offers ({ "models" => [{ "value", "display_name" }] })
  def models
    get_json("/models")
  end

  private
    attr_reader :url, :token, :time_zone

    def http
      Net::HTTP.new(url.host, url.port).tap do |connection|
        connection.use_ssl = url.scheme == "https"
        connection.open_timeout = CONNECT_TIMEOUT
        connection.read_timeout = READ_TIMEOUT
        connection.write_timeout = CONNECT_TIMEOUT
      end
    end

    def endpoint(path)
      "#{url.path}#{path}"
    end

    def headers
      { "Authorization" => "Bearer #{token}", "Accept" => "application/x-ndjson" }
    end

    def post_streaming(path, body)
      request = Net::HTTP::Post.new(endpoint(path), headers.merge("Content-Type" => "application/json"))
      request.body = body.to_json

      http.start do |connection|
        connection.request(request) do |response|
          @received_any = true
          raise refused(response, response.read_body.to_s) unless response.is_a?(Net::HTTPSuccess)

          read_lines(response) { |event| yield event }
        end
      end
    end

    def get_json(path)
      connection = http
      connection.read_timeout = STATUS_READ_TIMEOUT
      response = connection.start { |started| started.request(Net::HTTP::Get.new(endpoint(path), headers)) }
      body = response.body.to_s
      raise refused(response, body) unless response.is_a?(Net::HTTPSuccess)

      parse_line(body.byteslice(0, MAX_LINE_BYTES).lines.first) ||
        raise(Assistant::Claude::Error.new("bad_response", detail: "an empty answer", time_zone: time_zone))
    rescue Net::ReadTimeout
      raise Assistant::Claude::Error.new("timeout", time_zone: time_zone)
    rescue *UNREACHABLE_ERRORS => e
      raise unreachable(e)
    end

    def read_lines(response)
      buffer = +""

      response.read_body do |chunk|
        buffer << chunk
        while (newline = buffer.index("\n"))
          line = buffer.slice!(0..newline)
          event = parse_line(line)
          yield event if event
        end

        if buffer.bytesize > MAX_LINE_BYTES
          raise Assistant::Claude::Error.new("bad_response", detail: "a line is longer than 1 MB", time_zone: time_zone)
        end
      end

      event = parse_line(buffer)
      yield event if event
    end

    def parse_line(line)
      text = line.to_s.strip
      return if text.empty?

      parsed = JSON.parse(text)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      raise Assistant::Claude::Error.new("bad_response", detail: "a line is not JSON", time_zone: time_zone)
    end

    # A refused request (401 wrong token, 400 bad request, 429 busy) answers with one error line
    def refused(response, body)
      parsed = begin
        JSON.parse(body.to_s.byteslice(0, MAX_ERROR_BODY_BYTES).lines.first.to_s)
      rescue JSON::ParserError
        nil
      end

      if response.code.to_i == 401
        Assistant::Claude::Error.new("unauthorized", time_zone: time_zone)
      elsif parsed.is_a?(Hash) && parsed["code"].present?
        Assistant::Claude::Error.from_event(parsed, time_zone: time_zone)
      else
        Assistant::Claude::Error.new("bad_response", detail: "HTTP #{response.code}", time_zone: time_zone)
      end
    end

    def unreachable(exception)
      Rails.logger.warn("Claude bridge unreachable at #{url.host}:#{url.port}: #{exception.class}: #{exception.message}")
      Assistant::Claude::Error.new("unreachable", time_zone: time_zone)
    end
end
