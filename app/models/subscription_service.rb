class SubscriptionService < ApplicationRecord
  CATEGORIES = %w[streaming music software gaming news fitness storage cloud utilities education].freeze

  has_many :recurring_transactions, dependent: :nullify
  has_one_attached :icon

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :domain, presence: true
  validates :category, inclusion: { in: CATEGORIES }, allow_blank: true

  scope :search, ->(query) { where("name ILIKE ?", "%#{query}%") }
  scope :by_category, ->(category) { where(category: category) }
  scope :alphabetically, -> { order(:name) }

  def logo_url(size: nil)
    # Return cached local icon if available
    return Rails.application.routes.url_helpers.rails_blob_path(icon, only_path: true) if icon.attached?

    # Otherwise return Brandfetch CDN URL
    return nil unless Setting.brand_fetch_client_id.present?
    size ||= Setting.brand_fetch_logo_size
    "https://cdn.brandfetch.io/#{domain}/icon/fallback/lettermark/w/#{size}/h/#{size}?c=#{Setting.brand_fetch_client_id}"
  end
end
