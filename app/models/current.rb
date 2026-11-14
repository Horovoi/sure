class Current < ActiveSupport::CurrentAttributes
  attribute :user_agent, :ip_address

  attribute :session

  delegate :family, to: :user, allow_nil: true

  def user
    impersonated_user || session&.user
  end

  # Re-checked on every request: a super admin who was demoted stops
  # impersonating at once.
  def impersonated_user
    return nil unless session&.user&.super_admin?

    session.active_impersonator_session&.impersonated
  end

  def true_user
    session&.user
  end
end
