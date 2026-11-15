module StoreLocation
  extend ActiveSupport::Concern

  # The session lives in a 4 KB cookie. A return_to with a long query (a transactions
  # filter with many accounts) would overflow it and turn the next response into a 500.
  MAX_STORED_RETURN_TO_BYTES = 1024

  included do
    helper_method :previous_path
    before_action :store_return_to
    after_action :clear_previous_path

    rescue_from ActiveRecord::RecordNotFound, with: :handle_not_found
  end

  def previous_path
    sanitize_return_to(session[:return_to]) || fallback_path
  end

private
  def handle_not_found
    if request.fullpath == session[:return_to]
      session.delete(:return_to)
      redirect_to fallback_path
    else
      head :not_found
    end
  end

  # A value over the cap keeps only its path; a path that is still over the cap stores
  # nothing and drops the older value, so "back" never points to a stale page.
  def store_return_to
    return_to = sanitize_return_to(params[:return_to])
    return unless return_to

    return_to = return_to.split("?", 2).first if return_to.bytesize > MAX_STORED_RETURN_TO_BYTES

    if return_to.bytesize > MAX_STORED_RETURN_TO_BYTES
      session.delete(:return_to)
    else
      session[:return_to] = return_to
    end
  end

  def clear_previous_path
    if request.fullpath == session[:return_to]
      session.delete(:return_to)
    end
  end

  def fallback_path
    root_path
  end

  # Returns the value only when it is a path on this site ("/accounts"),
  # never a URL with a scheme ("javascript:", "https:") or a protocol-relative
  # URL ("//evil.example", "/\evil.example"). Returns nil otherwise.
  def sanitize_return_to(value)
    return nil unless value.is_a?(String)
    return nil unless value.start_with?("/")
    return nil if value.start_with?("//", "/\\")
    return nil if value.match?(/[[:cntrl:][:space:]]/)

    uri = URI.parse(value)
    return nil if uri.scheme.present? || uri.host.present?

    value
  rescue URI::InvalidURIError
    nil
  end
end
