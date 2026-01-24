class CacheSubscriptionIconJob < ApplicationJob
  queue_as :default

  def perform(subscription_service)
    return if subscription_service.icon.attached?
    return unless Setting.brand_fetch_client_id.present?

    url = brandfetch_url(subscription_service.domain)
    response = HTTParty.get(url, timeout: 10)

    if response.success?
      subscription_service.icon.attach(
        io: StringIO.new(response.body),
        filename: "#{subscription_service.slug}.png",
        content_type: response.content_type
      )
    end
  rescue => e
    Rails.logger.warn "Failed to cache icon for #{subscription_service.name}: #{e.message}"
  end

  private

  def brandfetch_url(domain)
    size = Setting.brand_fetch_logo_size
    "https://cdn.brandfetch.io/#{domain}/icon/fallback/lettermark/w/#{size}/h/#{size}?c=#{Setting.brand_fetch_client_id}"
  end
end
