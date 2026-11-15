require "test_helper"

class FeatureFlagsTest < ActiveSupport::TestCase
  test "db_sso_providers? follows AUTH_PROVIDERS_SOURCE when it is set" do
    with_env_overrides("AUTH_PROVIDERS_SOURCE" => "db") { assert FeatureFlags.db_sso_providers? }
    with_env_overrides("AUTH_PROVIDERS_SOURCE" => " DB ") { assert FeatureFlags.db_sso_providers? }
    with_env_overrides("AUTH_PROVIDERS_SOURCE" => "yaml") { assert_not FeatureFlags.db_sso_providers? }
  end

  test "db_sso_providers? defaults to the database for a self-hosted instance outside test" do
    with_env_overrides("AUTH_PROVIDERS_SOURCE" => nil) do
      Rails.stubs(:env).returns(ActiveSupport::StringInquirer.new("production"))
      with_self_hosting { assert FeatureFlags.db_sso_providers? }
    end
  end

  test "db_sso_providers? defaults to YAML for a managed instance" do
    with_env_overrides("AUTH_PROVIDERS_SOURCE" => nil) do
      Rails.stubs(:env).returns(ActiveSupport::StringInquirer.new("production"))
      Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
      assert_not FeatureFlags.db_sso_providers?
    end
  end

  test "db_sso_providers? defaults to YAML in the test environment" do
    with_env_overrides("AUTH_PROVIDERS_SOURCE" => nil) do
      with_self_hosting { assert_not FeatureFlags.db_sso_providers? }
    end
  end
end
