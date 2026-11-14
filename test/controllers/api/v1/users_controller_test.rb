require "test_helper"

class Api::V1::UsersControllerTest < ActionDispatch::IntegrationTest
  def api_headers_for(user)
    user.api_keys.destroy_all
    key =ApiKey.create!(user: user, name: "Key", display_key: "users_#{SecureRandom.hex(8)}", scopes: [ "read_write" ])
    { "X-Api-Key" => key.display_key }
  end

  test "a family member cannot reset the family through the API" do
    assert_no_enqueued_jobs only: FamilyResetJob do
      delete "/api/v1/users/reset", headers: api_headers_for(users(:family_member))
    end

    assert_response :forbidden
  end

  test "a family admin can reset the family through the API" do
    assert_enqueued_with(job: FamilyResetJob) do
      delete "/api/v1/users/reset", headers: api_headers_for(users(:family_admin))
    end

    assert_response :success
  end
end
