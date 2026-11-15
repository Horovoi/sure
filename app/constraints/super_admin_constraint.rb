# Routing constraint for engines that bypass ApplicationController (Sidekiq::Web).
# It resolves the signed session cookie the same way Authentication#find_session_by_cookie
# does and lets the request through only for an active super admin.
#
# The session's user is always the true user: impersonation is resolved at the Current
# level, so an impersonated member never satisfies this. Sessions are created only after
# MFA verification, so this does not bypass MFA either.
#
# Fails closed: any error (garbage cookie, unreachable database) means the route does not
# exist for the request (404).
class SuperAdminConstraint
  def matches?(request)
    cookie_value = request.cookie_jar.signed[:session_token]
    return false if cookie_value.blank?

    user = Session.includes(:user).find_by(id: cookie_value)&.user
    user.present? && user.active? && user.super_admin?
  rescue => e
    Rails.logger.warn("SuperAdminConstraint rejected request: #{e.class}: #{e.message}")
    false
  end
end
