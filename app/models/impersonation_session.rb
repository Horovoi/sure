class ImpersonationSession < ApplicationRecord
  include AASM

  # An approved session stops working after this long, even if nobody ends it.
  # The stale-work reaper then completes it (see .expired).
  IN_PROGRESS_TTL = 2.hours

  belongs_to :impersonator, class_name: "User"
  belongs_to :impersonated, class_name: "User"

  has_many :logs, class_name: "ImpersonationSessionLog"

  # pending -> in_progress (approved) -> complete; pending -> rejected.
  # Locked, so a concurrent approve and complete cannot both apply.
  aasm column: :status, requires_lock: true, whiny_persistence: true do
    state :pending, initial: true
    state :in_progress
    state :complete
    state :rejected

    event :approve do
      transitions from: :pending, to: :in_progress, guard: :impersonator_still_super_admin?
    end

    event :reject, after_commit: :detach_sessions! do
      transitions from: :pending, to: :rejected
    end

    # Ending a session (or cancelling a request that was never approved)
    event :complete, after_commit: :detach_sessions! do
      transitions from: %i[pending in_progress], to: :complete
    end
  end

  scope :initiated, -> { where(status: %w[pending in_progress]) }
  # Approved sessions whose TTL has passed (status changes are the only
  # updates, so updated_at is when the session was approved)
  scope :expired, -> { in_progress.where(updated_at: ...IN_PROGRESS_TTL.ago) }
  scope :active, -> { in_progress.where(updated_at: IN_PROGRESS_TTL.ago..) }

  validate :impersonator_is_super_admin, on: :create
  validate :impersonated_is_not_super_admin, on: :create
  validate :impersonator_different_from_impersonated

  def self.complete_expired!
    expired.find_each do |impersonation_session|
      impersonation_session.complete! if impersonation_session.may_complete?
    rescue AASM::InvalidTransition
      next # completed concurrently
    end
  end

  def expired?
    in_progress? && updated_at < IN_PROGRESS_TTL.ago
  end

  private
    def impersonator_still_super_admin?
      impersonator.super_admin?
    end

    # No browser session may keep pointing at an ended session, so it can
    # never silently resume.
    def detach_sessions!
      Session.where(active_impersonator_session_id: id).update_all(active_impersonator_session_id: nil)
    end

    def impersonator_is_super_admin
      errors.add(:impersonator, "must be a super admin to impersonate") unless impersonator&.super_admin?
    end

    def impersonated_is_not_super_admin
      errors.add(:impersonated, "cannot be a super admin") if impersonated&.super_admin?
    end

    def impersonator_different_from_impersonated
      errors.add(:impersonator, "cannot be the same as the impersonated user") if impersonator == impersonated
    end
end
