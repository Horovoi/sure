class User < ApplicationRecord
  # Allow nil password for SSO-only users (JIT provisioning).
  # Custom validation ensures password is present for non-SSO registration.
  has_secure_password validations: false

  belongs_to :family
  belongs_to :last_viewed_chat, class_name: "Chat", optional: true
  has_many :sessions, dependent: :destroy
  has_many :chats, dependent: :destroy
  has_many :api_keys, dependent: :destroy
  has_many :mobile_devices, dependent: :destroy
  has_many :invitations, foreign_key: :inviter_id, dependent: :destroy
  has_many :impersonator_support_sessions, class_name: "ImpersonationSession", foreign_key: :impersonator_id, dependent: :destroy
  has_many :impersonated_support_sessions, class_name: "ImpersonationSession", foreign_key: :impersonated_id, dependent: :destroy
  has_many :oidc_identities, dependent: :destroy
  has_many :sso_audit_logs, dependent: :nullify
  accepts_nested_attributes_for :family, update_only: true

  # w2-transfers default-account: the account new entries start in (see #default_account_for_entries)
  belongs_to :default_account, class_name: "Account", optional: true, inverse_of: :default_for_users
  validate :default_account_in_family

  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validate :ensure_valid_profile_image
  validates :default_period, inclusion: { in: Period::PERIODS.keys }
  validates :default_account_order, inclusion: { in: AccountOrder::ORDERS.keys }

  # Password is required on create unless the user is being created via SSO JIT.
  # SSO JIT users have password_digest = nil and authenticate via OIDC only.
  validates :password, presence: true, on: :create, unless: :skip_password_validation?
  validates :password, length: { minimum: 8 }, allow_nil: true
  validates :password, confirmation: true, allow_nil: true # only checked when a confirmation is sent
  normalizes :email, with: ->(email) { email.strip.downcase }
  normalizes :unconfirmed_email, with: ->(email) { email&.strip&.downcase }

  normalizes :first_name, :last_name, with: ->(value) { value.strip.presence }

  enum :role, { member: "member", admin: "admin", super_admin: "super_admin" }, validate: true

  # Returns the appropriate role for a new user creating a family.
  # The very first user of an instance becomes super_admin; subsequent users
  # get the specified fallback role (typically :admin for family creators).
  def self.role_for_new_family_creator(fallback_role: :admin)
    User.exists? ? fallback_role : :super_admin
  end

  has_one_attached :profile_image do |attachable|
    attachable.variant :thumbnail, resize_to_fill: [ 300, 300 ], convert: :webp, saver: { quality: 80 }
    attachable.variant :small, resize_to_fill: [ 72, 72 ], convert: :webp, saver: { quality: 80 }, preprocessed: true
  end

  validate :profile_image_size

  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt&.last(10)
  end

  generates_token_for :email_confirmation, expires_in: 1.day do
    unconfirmed_email
  end

  # w2-transfers default-account: the default account when the forms may preselect it
  # (manual and active, Account#eligible_as_default?), else nil
  def default_account_for_entries
    account = default_account
    account if account&.family_id == family_id && account.eligible_as_default?
  end

  def pending_email_change?
    unconfirmed_email.present?
  end

  def initiate_email_change(new_email)
    return false if new_email == email

    if Rails.application.config.app_mode.self_hosted? && !Setting.require_email_confirmation
      update(email: new_email)
    else
      if update(unconfirmed_email: new_email)
        EmailConfirmationMailer.with(user: self).confirmation_email.deliver_later
        true
      else
        false
      end
    end
  end

  def resend_confirmation_email
    if pending_email_change?
      EmailConfirmationMailer.with(user: self).confirmation_email.deliver_later
      true
    else
      false
    end
  end

  def request_impersonation_for(user_id)
    impersonated = User.find(user_id)
    impersonator_support_sessions.create!(impersonated: impersonated)
  end

  def admin?
    super_admin? || role == "admin"
  end

  def display_name
    [ first_name, last_name ].compact.join(" ").presence || email
  end

  def initial
    (display_name&.first || email.first).upcase
  end

  def initials
    if first_name.present? && last_name.present?
      "#{first_name.first}#{last_name.first}".upcase
    else
      initial
    end
  end

  def show_ai_sidebar?
    show_ai_sidebar
  end

  # OpenAI is configured, or the Claude bridge on the Mac is (CLAUDE_BRIDGE_URL and CLAUDE_BRIDGE_TOKEN)
  def ai_available?
    !Rails.application.config.app_mode.self_hosted? ||
      ENV["OPENAI_ACCESS_TOKEN"].present? ||
      Setting.openai_access_token.present? ||
      Assistant::Claude.configured?
  end

  def ai_enabled?
    ai_enabled && ai_available?
  end

  # SSO-only users have OIDC identities but no local password.
  # They cannot use password reset or local login.
  def sso_only?
    password_digest.nil? && oidc_identities.exists?
  end

  # Check if user has a local password set (can authenticate locally)
  def has_local_password?
    password_digest.present?
  end

  # Attribute to skip password validation during SSO JIT provisioning
  attr_accessor :skip_password_validation

  # Deactivation
  validate :can_deactivate, if: -> { active_changed? && !active }
  after_update_commit :purge_later, if: -> { saved_change_to_active?(from: true, to: false) }

  # Deactivating revokes every credential at once: until the purge job runs
  # (or if it fails) nothing may still authenticate as this user.
  def deactivate
    transaction do
      next false unless update(active: false, email: deactivated_email, unconfirmed_email: nil)

      revoke_all_credentials!
      true
    end
  end

  def revoke_all_credentials!
    now = Time.current
    Session.where(user_id: id).delete_all
    api_keys.where(revoked_at: nil).update_all(revoked_at: now)
    Doorkeeper::AccessToken.where(resource_owner_id: id, revoked_at: nil).update_all(revoked_at: now)
    Doorkeeper::AccessGrant.where(resource_owner_id: id, revoked_at: nil).update_all(revoked_at: now)
  end

  # A password, email or MFA change signs out every other browser: a stolen
  # session cookie must not outlive the credential change. The session that
  # made the change stays signed in (unless it belongs to someone else, e.g.
  # an impersonating admin, or there is none, e.g. a password reset link).
  after_update_commit :revoke_other_sessions, if: :credentials_changed_on_save?

  def revoke_other_sessions(keep: Current.session)
    others = Session.where(user_id: id)
    others = others.where.not(id: keep.id) if keep&.persisted? && keep.user_id == id && keep.active_impersonator_session_id.nil?
    others.delete_all
  end

  def can_deactivate
    if admin? && family.users.count > 1
      errors.add(:base, :cannot_deactivate_admin_with_other_users)
    end
  end

  def purge_later
    UserPurgeJob.perform_later(self)
  end

  # Locks the family so two purges in one family cannot both see another
  # member and leave the family with no users.
  def purge
    family.with_lock do
      if last_user_in_family?
        family.destroy
      else
        destroy
      end
    end
  end

  # MFA
  def setup_mfa!
    update!(
      otp_secret: ROTP::Base32.random(32),
      otp_required: false,
      otp_backup_codes: []
    )
  end

  def enable_mfa!
    update!(
      otp_required: true,
      otp_backup_codes: generate_backup_codes
    )
  end

  def disable_mfa!
    update!(
      otp_secret: nil,
      otp_required: false,
      otp_backup_codes: []
    )
  end

  def verify_otp?(code)
    return false if otp_secret.blank? || code.blank?
    return true if verify_backup_code?(code)
    totp.verify(code.to_s.strip, drift_behind: 15).present?
  end

  def provisioning_uri
    return nil unless otp_secret.present?
    totp.provisioning_uri(email)
  end

  def onboarded?
    onboarded_at.present?
  end

  def needs_onboarding?
    !onboarded?
  end

  def account_order
    AccountOrder.find(default_account_order) || AccountOrder.default
  end

  # Dashboard preferences management
  def dashboard_section_collapsed?(section_key)
    preferences&.dig("collapsed_sections", section_key) == true
  end

  def dashboard_section_order
    preferences&.[]("section_order") || default_dashboard_section_order
  end

  # laid_out_order is the order the dashboard laid its widgets out in. It also places
  # widgets the saved order does not list yet.
  def update_dashboard_preferences(prefs, laid_out_order: nil)
    prefs = prefs.to_h.stringify_keys
    if prefs["section_order"]
      prefs["section_order"] = keep_hidden_sections_in_order(Array(prefs["section_order"]), laid_out_order || dashboard_section_order)
    end

    merge_preferences(prefs)
  end

  # Dashboard widgets the user hid in Customize mode. Stored as
  # hidden_sections: { key => true/false }, merged key by key like collapsed_sections,
  # so a stale tab that hides one widget cannot bring back another.
  def dashboard_section_hidden?(section_key)
    preferences&.dig("hidden_sections", section_key) == true
  end

  def dashboard_hidden_sections
    hidden = preferences&.[]("hidden_sections")
    hidden.is_a?(Hash) ? hidden.select { |_key, value| value == true }.keys : []
  end

  # Reports preferences management
  def reports_section_collapsed?(section_key)
    preferences&.dig("reports_collapsed_sections", section_key) == true
  end

  def reports_section_order
    preferences&.[]("reports_section_order") || default_reports_section_order
  end

  # How the Reports expenses treemap colours its tiles: by category, or by the change
  # against normal spending
  REPORTS_EXPENSE_COLOR_MODES = %w[category normal].freeze

  def reports_expense_color_mode
    mode = preferences&.[]("reports_expense_color_mode")
    REPORTS_EXPENSE_COLOR_MODES.include?(mode) ? mode : REPORTS_EXPENSE_COLOR_MODES.first
  end

  # Saved preferences can name sections Reports no longer has (Spending vs normal is
  # now part of the activity breakdown). The page skips keys it does not know, so they
  # stay harmless and need no migration.
  def update_reports_preferences(prefs)
    prefs = prefs.to_h.stringify_keys
    if prefs.key?("reports_expense_color_mode") && !REPORTS_EXPENSE_COLOR_MODES.include?(prefs["reports_expense_color_mode"])
      return false
    end

    merge_preferences(prefs)
  end

  # Transactions preferences management
  def transactions_section_collapsed?(section_key)
    preferences&.dig("transactions_collapsed_sections", section_key) == true
  end

  def update_transactions_preferences(prefs)
    merge_preferences(prefs.transform_keys { |key| "transactions_#{key}" })
  end

  private
    def default_account_in_family
      return if default_account_id.blank?

      errors.add(:default_account, :invalid) unless default_account&.family_id == family_id
    end

    # Merges into the stored preferences: a hash value (collapsed sections) is merged
    # key by key, anything else (section order) replaces the stored value. The row
    # lock makes the read-modify-write atomic when sections are toggled quickly.
    def merge_preferences(prefs)
      transaction do
        lock!

        merged = (preferences || {}).deep_dup
        prefs.each do |key, value|
          merged[key] = value.is_a?(Hash) ? (merged[key] || {}).merge(value) : value
        end

        update!(preferences: merged)
      end
    end

    def credentials_changed_on_save?
      return false if saved_change_to_active? # deactivation revokes everything itself

      saved_change_to_password_digest? || saved_change_to_email? || saved_change_to_otp_required?
    end

    def skip_password_validation?
      skip_password_validation == true
    end

    # The dashboard sends only the order of the widgets it rendered, so each hidden
    # widget goes back after the widget it followed before
    def keep_hidden_sections_in_order(new_order, old_order)
      hidden = dashboard_hidden_sections
      (old_order & hidden).reduce(new_order - hidden) do |order, key|
        predecessor = old_order[0...old_order.index(key)].reverse.find { |k| order.include?(k) }
        order.insert(predecessor ? order.index(predecessor) + 1 : 0, key)
      end
    end

    def default_dashboard_section_order
      %w[cashflow_sankey outflows_donut net_worth_chart balance_sheet]
    end

    def default_reports_section_order
      %w[trends_insights transactions_breakdown]
    end
    def ensure_valid_profile_image
      return unless profile_image.attached?

      unless profile_image.content_type.in?(%w[image/jpeg image/png])
        errors.add(:profile_image, "must be a JPEG or PNG")
        profile_image.purge
      end
    end

    def last_user_in_family?
      family.users.count == 1
    end

    def deactivated_email
      email.gsub(/@/, "-deactivated-#{SecureRandom.uuid}@")
    end

    def profile_image_size
      if profile_image.attached? && profile_image.byte_size > 10.megabytes
        errors.add(:profile_image, :invalid_file_size, max_megabytes: 10)
      end
    end

    def totp
      ROTP::TOTP.new(otp_secret, issuer: "Sure Finances")
    end

    # Consumes the code with one conditional UPDATE, so the same backup code
    # cannot be used twice by concurrent requests.
    def verify_backup_code?(code)
      return false if code.blank? || otp_backup_codes.blank?

      code = code.to_s.strip
      consumed = self.class.where(id: id)
        .where("? = ANY(otp_backup_codes)", code)
        .update_all([ "otp_backup_codes = array_remove(otp_backup_codes, ?)", code ]) == 1
      self.otp_backup_codes = otp_backup_codes - [ code ] if consumed
      clear_attribute_change(:otp_backup_codes) if consumed
      consumed
    end

    def generate_backup_codes
      8.times.map { SecureRandom.hex(4) }
    end
end
