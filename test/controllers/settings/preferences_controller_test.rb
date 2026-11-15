require "test_helper"

class Settings::PreferencesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end
  test "get" do
    get settings_preferences_url
    assert_response :success
  end

  # --- Enabled currencies (w1-ds money field) ---

  test "an admin sees the currency settings with the family's selection" do
    family = users(:family_admin).family
    family.update!(currency: "UAH", enabled_currencies: [ "UAH", "USD" ])

    get settings_preferences_url

    assert_response :success
    assert_select "[data-controller=currency-preferences]"
    assert_select "input[type=checkbox][name='user[family_attributes][enabled_currencies][]'][value=USD][checked]"
    assert_select "input[type=checkbox][name='user[family_attributes][enabled_currencies][]'][value=EUR]:not([checked])"
    assert_select "input[type=checkbox][value=UAH][disabled]"
  end

  test "a member does not see the currency settings" do
    sign_in users(:family_member)

    get settings_preferences_url

    assert_response :success
    assert_select "[data-controller=currency-preferences]", count: 0
  end
end
