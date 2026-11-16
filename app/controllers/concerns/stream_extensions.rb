module StreamExtensions
  extend ActiveSupport::Concern

  def stream_redirect_to(path, notice: nil, alert: nil)
    custom_stream_redirect(path, notice: notice, alert: alert)
  end

  def stream_redirect_back_or_to(path, notice: nil, alert: nil)
    custom_stream_redirect(path, redirect_back: true, notice: notice, alert: alert)
  end

  private
    def custom_stream_redirect(path, redirect_back: false, notice: nil, alert: nil)
      flash[:notice] = notice if notice.present?
      flash[:alert] = alert if alert.present?

      # Without a referer (a typed URL, a privacy setting) "back" is the given path
      redirect_target_url = redirect_back ? (request.referer.presence || path) : path
      render turbo_stream: turbo_stream.action(:redirect, redirect_target_url)
    end

    # The page the request came from, unless it is one of `paths`: a page that no longer
    # shows what it showed (the record just deleted) or that would open again (the
    # editor just saved), or another site's. nil then, and the caller goes to its own
    # fallback.
    def referer_unless(*paths)
      referer = request.referer.presence
      return nil unless referer

      uri = URI.parse(referer)
      # Another site is never "back" (redirect_back_or_to refuses it too)
      return nil if uri.host.present? && uri.host != request.host

      paths.compact.include?(uri.path) ? nil : referer
    rescue URI::InvalidURIError
      nil
    end
end
