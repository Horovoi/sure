require "test_helper"

class ImpersonationSessionTest < ActiveSupport::TestCase
  test "only super admin can impersonate" do
    regular_user = users(:family_member)

    assert_not regular_user.super_admin?

    assert_raises(ActiveRecord::RecordInvalid) do
      ImpersonationSession.create!(
        impersonator: regular_user,
        impersonated: users(:sure_support_staff)
      )
    end
  end

  test "super admin cannot be impersonated" do
    super_admin = users(:sure_support_staff)

    assert super_admin.super_admin?

    assert_raises(ActiveRecord::RecordInvalid) do
      ImpersonationSession.create!(
        impersonator: users(:family_member),
        impersonated: super_admin
      )
    end
  end

  test "impersonation session must have different impersonator and impersonated" do
    super_admin = users(:sure_support_staff)

    assert_raises(ActiveRecord::RecordInvalid) do
      ImpersonationSession.create!(
        impersonator: super_admin,
        impersonated: super_admin
      )
    end
  end

  test "approve, reject and complete are only allowed from the right state" do
    session = ImpersonationSession.create!(impersonator: users(:sure_support_staff), impersonated: users(:family_member))
    assert session.pending?

    session.approve!
    assert session.in_progress?
    assert_raises(AASM::InvalidTransition) { session.approve! }
    assert_raises(AASM::InvalidTransition) { session.reject! }

    session.complete!
    assert session.complete?
    assert_raises(AASM::InvalidTransition) { session.approve! }
    assert_raises(AASM::InvalidTransition) { session.complete! }
  end

  test "approve is refused once the impersonator is no longer a super admin" do
    session = ImpersonationSession.create!(impersonator: users(:sure_support_staff), impersonated: users(:family_member))
    users(:sure_support_staff).update_column(:role, "admin")

    assert_raises(AASM::InvalidTransition) { session.reload.approve! }
  end

  test "a session can be completed after the impersonator was demoted" do
    session = impersonation_sessions(:in_progress)
    users(:sure_support_staff).update_column(:role, "admin")

    session.reload.complete!

    assert session.complete?
  end
end
