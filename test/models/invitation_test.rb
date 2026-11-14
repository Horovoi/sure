require "test_helper"

class InvitationTest < ActiveSupport::TestCase
  setup do
    @admin = users(:family_admin)
    @family = @admin.family
  end

  test "inviter must be an admin" do
    invitation = @family.invitations.build(email: "x@example.com", role: "member", inviter: users(:family_member))

    assert_not invitation.valid?
    assert invitation.errors[:inviter].any?
  end

  test "accept_for refuses an invitation that is no longer pending" do
    user = users(:empty)
    invitation = @family.invitations.create!(email: user.email, role: "member", inviter: @admin)
    Invitation.where(id: invitation.id).update_all(accepted_at: 1.minute.ago)

    assert_not invitation.accept_for(user)
    assert_equal families(:empty), user.reload.family
  end

  test "accept_for refuses when the user is the only admin of a family with other members" do
    sole_admin = User.create!(family: families(:empty), email: "sole@example.com", password: "Password1!", role: "admin")
    families(:empty).users.where.not(id: sole_admin.id).update_all(role: "member")

    other_family = Family.create!(name: "Other")
    inviter = User.create!(family: other_family, email: "inviter@example.com", password: "Password1!", role: "admin")
    invitation = other_family.invitations.create!(email: sole_admin.email, role: "member", inviter: inviter)

    assert_not invitation.accept_for(sole_admin)
    assert invitation.errors[:base].any?
    assert_equal families(:empty), sole_admin.reload.family
  end

  test "claim_for_signup! succeeds only once" do
    invitation = @family.invitations.create!(email: "new@example.com", role: "member", inviter: @admin)
    stale_copy = Invitation.find(invitation.id)

    assert invitation.claim_for_signup!
    assert_not stale_copy.claim_for_signup!
  end

  test "clear_lapsed_for! removes expired and accepted invitations only" do
    pending = @family.invitations.create!(email: "pending@example.com", role: "member", inviter: @admin)
    expired = @family.invitations.create!(email: "expired@example.com", role: "member", inviter: @admin)
    expired.update_columns(expires_at: 1.day.ago)

    Invitation.clear_lapsed_for!(family: @family, email: "EXPIRED@example.com ")
    Invitation.clear_lapsed_for!(family: @family, email: "pending@example.com")

    assert_not Invitation.exists?(expired.id)
    assert Invitation.exists?(pending.id)
  end
end
