require "test_helper"

class UserFixtureDigestsTest < ActiveSupport::TestCase
  # Verifying a bcrypt digest costs what the digest says, whatever
  # ActiveModel::SecurePassword.min_cost is, so a production-cost fixture digest
  # makes every sign_in in the suite about 230ms slower.
  test "user fixtures store the test password at bcrypt MIN_COST" do
    digests = User.where.not(password_digest: nil).pluck(:email, :password_digest)
    assert_not_empty digests

    digests.each do |email, digest|
      password = BCrypt::Password.new(digest)
      assert_equal BCrypt::Engine::MIN_COST, password.cost, "#{email} has a cost #{password.cost} digest"
      assert password == user_password_test, "#{email} does not take the test password"
    end
  end
end
