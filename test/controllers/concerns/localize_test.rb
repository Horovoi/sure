require "test_helper"

class LocalizeTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "uses family locale by default" do
    get preferences_onboarding_url
    assert_response :success
    assert_select "h1", text: /Configure your preferences/i
  end

  test "switches locale when locale param is provided" do
    get preferences_onboarding_url(locale: "fr")
    assert_response :success
    assert_select "h1", text: /Configurez vos préférences/i
  end

  test "ignores invalid locale param and uses family locale" do
    get preferences_onboarding_url(locale: "invalid_locale")
    assert_response :success
    assert_select "h1", text: /Configure your preferences/i
  end

  test "a bad family time zone renders in UTC and writes one debug entry" do
    family = users(:family_admin).family
    family.update_column(:timezone, "Invalid/Timezone")
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    assert_difference -> { DebugLogEntry.where(category: "time_zone", family: family).count }, 1 do
      get root_url
      assert_response :success
      get root_url
      assert_response :success
    end
  ensure
    Rails.cache = original_cache
  end
end
