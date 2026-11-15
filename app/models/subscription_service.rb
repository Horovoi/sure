class SubscriptionService < ApplicationRecord
  CATEGORIES = %w[streaming music software gaming news fitness storage cloud utilities education].freeze

  has_many :recurring_transactions, dependent: :nullify

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :domain, presence: true
  validates :category, inclusion: { in: CATEGORIES }, allow_blank: true

  scope :search, ->(query) { where("name ILIKE ?", "%#{query}%") }
  scope :by_category, ->(category) { where(category: category) }
  scope :alphabetically, -> { order(:name) }

  def logo_url(size: nil)
    # Return static cached icon if available
    static_path = "icons/#{slug}.png"
    return "/#{static_path}" if Rails.root.join("public", static_path).exist?

    # Otherwise return Brandfetch CDN URL
    Setting.brand_fetch_icon_url(domain, width: size, height: size)
  end
end
