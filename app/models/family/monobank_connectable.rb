module Family::MonobankConnectable
  extend ActiveSupport::Concern

  included do
    has_many :monobank_items, dependent: :destroy
  end

  def can_connect_monobank?
    defined?(BankConnections) && BankConnections.enabled?(:monobank)
  end

  # Creates a monobank connection for a personal token and starts its first sync.
  def create_monobank_item!(access_token:, name: nil, sync_start_date: nil)
    monobank_item = monobank_items.create!(
      name: name.presence || I18n.t("monobank_items.defaults.name"),
      access_token: access_token,
      sync_start_date: sync_start_date
    )

    monobank_item.sync_later
    monobank_item
  end

  def has_monobank_credentials?
    monobank_items.active.any?(&:credentials_configured?)
  end
end
