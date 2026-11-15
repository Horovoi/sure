module MonobankItem::Provided
  extend ActiveSupport::Concern

  # API client for this connection's token, or nil without one
  def monobank_provider
    return nil unless credentials_configured?

    Provider::Monobank.new(access_token)
  end
end
