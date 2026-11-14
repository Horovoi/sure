module StoreLocation
  extend ActiveSupport::Concern

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

  def store_return_to
    if (return_to = sanitize_return_to(params[:return_to]))
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
