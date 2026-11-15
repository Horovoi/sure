require "test_helper"

class ProviderLoaderTest < ActiveSupport::TestCase
  setup do
    ProviderLoader.clear_cache
    @yaml_names = Rails.application.config_for(:auth).dig("providers").map { |p| p[:name].to_s }
  end

  teardown do
    ProviderLoader.clear_cache
  end

  test "db source loads only the enabled providers from the database" do
    create_provider(name: "db_keycloak", enabled: true)
    create_provider(name: "db_disabled", enabled: false)

    providers = with_env_overrides("AUTH_PROVIDERS_SOURCE" => "db") { ProviderLoader.load_providers }

    assert_equal [ "db_keycloak" ], provider_names(providers)
  end

  test "db source falls back to YAML when no database provider is enabled" do
    create_provider(name: "db_disabled", enabled: false)

    providers = with_env_overrides("AUTH_PROVIDERS_SOURCE" => "db") { ProviderLoader.load_providers }

    assert_equal @yaml_names, provider_names(providers)
  end

  test "yaml source ignores database providers" do
    create_provider(name: "db_keycloak", enabled: true)

    providers = with_env_overrides("AUTH_PROVIDERS_SOURCE" => "yaml") { ProviderLoader.load_providers }

    assert_equal @yaml_names, provider_names(providers)
    assert_not_includes provider_names(providers), "db_keycloak"
  end

  test "the test environment uses YAML when AUTH_PROVIDERS_SOURCE is unset" do
    create_provider(name: "db_keycloak", enabled: true)

    providers = with_env_overrides("AUTH_PROVIDERS_SOURCE" => nil) do
      with_self_hosting { ProviderLoader.load_providers }
    end

    assert_equal @yaml_names, provider_names(providers)
  end

  private
    def create_provider(name:, enabled:)
      SsoProvider.create!(
        strategy: "openid_connect",
        name: name,
        label: name.titleize,
        enabled: enabled,
        issuer: "https://#{name}.example.com",
        client_id: "#{name}_client",
        client_secret: "#{name}_secret"
      )
    end

    def provider_names(providers)
      providers.map { |p| (p[:name] || p["name"]).to_s }
    end
end
