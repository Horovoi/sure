require "test_helper"

class Admin::SsoProvidersControllerTest < ActionDispatch::IntegrationTest
  setup do
    SsoProvider.create!(
      strategy: "openid_connect",
      name: "db_keycloak",
      label: "Sign in with Keycloak",
      enabled: true,
      issuer: "https://keycloak.example.com",
      client_id: "keycloak_client",
      client_secret: "keycloak_secret"
    )
  end

  test "index shows database-backed providers as enabled when AUTH_PROVIDERS_SOURCE is db" do
    sign_in users(:sure_support_staff)

    with_env_overrides("AUTH_PROVIDERS_SOURCE" => "db") do
      get admin_sso_providers_path
    end

    assert_response :success
    assert_select "p", text: "Sign in with Keycloak"
    assert_select "button[aria-label=?]", "Disable"
    assert_select "code", text: "AUTH_PROVIDERS_SOURCE=db"
    assert_no_match "Changes require a server restart to take effect.", response.body
  end

  test "index shows database-backed providers as disabled and warns about restarts on the YAML source" do
    sign_in users(:sure_support_staff)

    with_env_overrides("AUTH_PROVIDERS_SOURCE" => "yaml") do
      get admin_sso_providers_path
    end

    assert_response :success
    assert_select "span.text-warning", text: "Changes require a server restart to take effect."
    assert_select "p", text: "Database-backed providers"
  end

  test "index is for super admins only" do
    sign_in users(:family_admin)

    get admin_sso_providers_path

    assert_redirected_to root_path
  end
end
