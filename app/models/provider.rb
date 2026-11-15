class Provider
  Response = Data.define(:success?, :data, :error)

  class Error < StandardError
    attr_reader :details, :failure_code

    # details: opaque response metadata (for example the response body).
    # failure_code: an optional Symbol that names the reason (:rate_limited,
    # :unauthorized, ...), so callers branch on it instead of on the message.
    def initialize(message, details: nil, failure_code: nil)
      super(message)
      @details = details
      @failure_code = failure_code
    end

    def as_json
      {
        message: message,
        details: details,
        failure_code: failure_code
      }
    end
  end

  private
    PaginatedData = Data.define(:paginated, :first_page, :total_pages)
    UsageData = Data.define(:used, :limit, :utilization, :plan)

    def with_provider_response(error_transformer: nil, &block)
      data = yield

      Response.new(
        success?: true,
        data: data,
        error: nil,
      )
    rescue => error
      transformed_error = if error_transformer
        error_transformer.call(error)
      else
        default_error_transformer(error)
      end

      Response.new(
        success?: false,
        data: nil,
        error: transformed_error
      )
    end

    # Override to set class-level error transformation for methods using `with_provider_response`.
    # An error that is already this provider's own (its Error or a subclass) is kept as it is.
    def default_error_transformer(error)
      if error.is_a?(self.class::Error)
        error
      elsif error.is_a?(Faraday::Error)
        self.class::Error.new(
          error.message,
          details: error.response&.dig(:body),
        )
      else
        self.class::Error.new(error.message)
      end
    end
end
