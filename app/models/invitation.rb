class Invitation < ApplicationRecord
  belongs_to :family
  belongs_to :inviter, class_name: "User"

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :role, presence: true, inclusion: { in: %w[admin member] }
  validates :token, presence: true, uniqueness: true
  validates_uniqueness_of :email, scope: :family_id, message: "has already been invited to this family"
  validate :inviter_is_admin, on: :create

  before_validation :generate_token, on: :create
  before_create :set_expiration

  scope :pending, -> { where(accepted_at: nil).where("expires_at > ?", Time.current) }
  scope :accepted, -> { where.not(accepted_at: nil) }
  scope :lapsed, -> { where.not(accepted_at: nil).or(where(expires_at: ..Time.current)) }

  # An expired or accepted invitation must not block inviting the same email
  # again (the email is unique per family), so drop those before inviting.
  def self.clear_lapsed_for!(family:, email:)
    family.invitations.lapsed.where(email: email.to_s.strip.downcase).delete_all
  end

  def pending?
    accepted_at.nil? && expires_at > Time.current
  end

  # Moves an existing user into this invitation's family. Callers must only
  # do this on the user's own explicit action, from their own session.
  # A super admin keeps their role. A family admin who would leave other
  # members without an admin cannot accept.
  def accept_for(user)
    return false if user.blank?
    return false unless emails_match?(user)

    accepted = false

    transaction do
      lock!
      next unless pending?

      if leaves_family_without_admin?(user)
        errors.add(:base, :leaves_family_without_admin)
        next
      end

      new_role = user.super_admin? ? "super_admin" : role.to_s
      user.update!(family_id: family_id, role: new_role)
      update!(accepted_at: Time.current)
      accepted = true
    end

    accepted
  end

  # Marks the invitation used by a brand-new signup. A single conditional
  # UPDATE, so two signups cannot both use one invitation.
  def claim_for_signup!
    claimed = self.class.pending.where(id: id).update_all(accepted_at: Time.current, updated_at: Time.current) == 1
    reload if claimed
    claimed
  end

  private
    def emails_match?(user)
      invitation_email = email.to_s.strip.downcase
      user_email = user.email.to_s.strip.downcase
      invitation_email.present? && user_email.present? && invitation_email == user_email
    end

    def leaves_family_without_admin?(user)
      return false if user.family_id == family_id
      return false unless user.admin?

      others = User.where(family_id: user.family_id).where.not(id: user.id)
      others.exists? && !others.where(role: %w[admin super_admin]).exists?
    end

    def generate_token
      loop do
        self.token = SecureRandom.hex(32)
        break unless self.class.exists?(token: token)
      end
    end

    def set_expiration
      self.expires_at = 3.days.from_now
    end

    def inviter_is_admin
      errors.add(:inviter, "must be an admin") unless inviter&.admin?
    end
end
