class FamilyMerchant < Merchant
  COLORS = %w[#e99537 #4da568 #6471eb #db5a54 #df4e92 #c44fe9 #eb5429 #61c9ea #805dee #6ad28a]
  LOGO_CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze
  LOGO_MAX_SIZE = 5.megabytes

  belongs_to :family

  # Set by the form's "Remove uploaded logo" toggle
  attribute :remove_logo, :boolean, default: false

  before_validation :set_default_color
  before_save :generate_logo_url_from_website, if: :should_generate_logo?
  # A logo uploaded in the same save wins over the toggle. Detaching destroys the
  # attachment, whose blob is purged after the commit (dependent: :purge_later).
  before_save :detach_logo, if: -> { remove_logo && !attachment_changes.key?("logo") }

  validates :color, presence: true
  validates :name, uniqueness: { scope: :family }
  validate :logo_is_small_image, if: -> { logo.attached? }

  # An uploaded logo comes before the website logo. The path is a signed-in route:
  # config/initializers/active_storage_authorization.rb serves it to this family only.
  def logo_url
    return super unless logo.attached? && logo.persisted?

    Rails.application.routes.url_helpers.rails_representation_path(logo.variant(:small), only_path: true)
  end

  private
    def detach_logo
      self.logo = nil
      self.remove_logo = false
    end

    def logo_is_small_image
      errors.add(:logo, :invalid_content_type) unless logo.content_type.in?(LOGO_CONTENT_TYPES)
      errors.add(:logo, :invalid_file_size, max_megabytes: LOGO_MAX_SIZE / 1.megabyte) if logo.byte_size > LOGO_MAX_SIZE
    end

    # Only fill a missing colour; a colour the user picked must survive saves.
    def set_default_color
      self.color = COLORS.sample if color.blank?
    end

    def should_generate_logo?
      website_url_changed? || (website_url.present? && self[:logo_url].blank?)
    end

    def generate_logo_url_from_website
      if website_url.present? && Setting.brand_fetch_client_id.present?
        self.logo_url = Setting.brand_fetch_icon_url(extract_domain(website_url))
      elsif website_url.blank?
        self.logo_url = nil
      end
    end

    def extract_domain(url)
      original_url = url
      normalized_url = url.start_with?("http://", "https://") ? url : "https://#{url}"
      URI.parse(normalized_url).host&.sub(/\Awww\./, "")
    rescue URI::InvalidURIError
      original_url.sub(/\Awww\./, "")
    end
end
