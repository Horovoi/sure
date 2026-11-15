require "test_helper"

class LocalizeTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "uses family locale by default" do
    get preferences_onboarding_url
    assert_response :success
    assert_select "h1", text: /Configure your preferences/i
    assert_select "html[lang=en]"
  end

  test "switches locale when locale param is provided" do
    get preferences_onboarding_url(locale: "fr")
    assert_response :success
    assert_select "h1", text: /Configurez vos préférences/i
    assert_select "html[lang=fr]"
  end

  test "ignores invalid locale param and uses family locale" do
    get preferences_onboarding_url(locale: "invalid_locale")
    assert_response :success
    assert_select "h1", text: /Configure your preferences/i
  end

  test "a locale param that is loaded but not supported is ignored" do
    assert_includes I18n.available_locales, :uk, "Rails' default uk file should be loaded for this test to mean anything"

    get preferences_onboarding_url(locale: "uk")
    assert_response :success
    assert_select "html[lang=en]"
    assert_select "h1", text: /Configure your preferences/i
  end

  test "a family locale that is not supported falls back to English" do
    users(:family_admin).family.update_column(:locale, "uk")

    get preferences_onboarding_url, headers: { "Accept-Language" => "uk" }
    assert_response :success
    assert_select "html[lang=en]"
  end

  test "the family locale wins over the Accept-Language header" do
    users(:family_admin).family.update_column(:locale, "en")

    get preferences_onboarding_url, headers: { "Accept-Language" => "de" }
    assert_response :success
    assert_select "html[lang=en]"
  end

  test "the locale param wins over the family locale" do
    users(:family_admin).family.update_column(:locale, "de")

    get preferences_onboarding_url(locale: "fr")
    assert_response :success
    assert_select "html[lang=fr]"
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

class LocalizeAcceptLanguageTest < ActionDispatch::IntegrationTest
  test "an unsupported first choice falls through to the next supported one" do
    assert_locale "en", "uk,en;q=0.8"
  end

  test "a lower q-value still wins when the higher ones are not supported" do
    assert_locale "de", "uk, de;q=0.5"
  end

  test "a regional variant matches its language" do
    assert_locale "de", "de-AT"
  end

  test "a regional locale that is supported is used as is" do
    assert_locale "pt-BR", "pt-br,en;q=0.5"
  end

  test "higher q-values come first" do
    assert_locale "fr", "de;q=0.4, fr;q=0.9, en;q=0.1"
  end

  test "equal q-values keep the header order" do
    assert_locale "fr", "fr;q=0.7, de;q=0.7"
  end

  test "q=0 means not acceptable" do
    assert_locale "en", "de;q=0, en;q=0.5"
  end

  test "a bad q-value does not raise" do
    assert_locale "de", "de;q=abc, fr;q=0.9"
    assert_locale "fr", "de;q=-1, fr;q=0.9"
  end

  test "a header with nothing supported uses English" do
    assert_locale "en", "uk, ja;q=0.9, *;q=0.1"
  end

  test "no header uses English" do
    get new_session_url
    assert_response :success
    assert_select "html[lang=en]"
  end

  private
    def assert_locale(expected, header)
      get new_session_url, headers: { "Accept-Language" => header }
      assert_response :success
      assert_select "html[lang=?]", expected, { count: 1 }, "Accept-Language #{header.inspect}"
    end
end
