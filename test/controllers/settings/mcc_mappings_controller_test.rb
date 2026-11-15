require "test_helper"

class Settings::MccMappingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:dylan_family)
    @category = categories(:food_and_drink)
  end

  def mapping(key)
    MccCategoryMapping.find_by(family: @family, group_key: key)
  end

  test "an admin saves the choices and goes back to the page they came from" do
    sign_in users(:family_admin)
    MccCategoryMapping.create!(family: @family, group_key: "rent", disabled: true)

    patch settings_mcc_mapping_path,
          params: { mcc_mapping: { groups: { groceries: @category.id, taxi: "none", rent: "" } } },
          headers: { "HTTP_REFERER" => settings_providers_url }

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("settings.mcc_mappings.update.saved"), flash[:notice]
    assert_equal @category, mapping("groceries").category
    assert mapping("taxi").disabled?
    assert_nil mapping("rent")
  end

  test "without a referrer it goes to the provider settings" do
    sign_in users(:family_admin)

    patch settings_mcc_mapping_path, params: { mcc_mapping: { groups: { groceries: "none" } } }

    assert_redirected_to settings_providers_path
  end

  test "ignores another family's category and unknown groups" do
    sign_in users(:family_admin)

    patch settings_mcc_mapping_path,
          params: { mcc_mapping: { groups: { groceries: categories(:one).id, own_transfer: "none", nope: "none" } } }

    assert_response :redirect
    assert_empty MccCategoryMapping.where(family: @family)
  end

  test "a family member cannot change the choices" do
    sign_in users(:family_member)

    patch settings_mcc_mapping_path, params: { mcc_mapping: { groups: { groceries: "none" } } }

    assert_redirected_to settings_profile_path
    assert_nil mapping("groceries")
  end

  test "a malformed request is a bad request" do
    sign_in users(:family_admin)

    patch settings_mcc_mapping_path, params: { mcc_mapping: "groceries" }

    assert_response :bad_request
  end

  test "signed out users are sent to sign in" do
    patch settings_mcc_mapping_path, params: { mcc_mapping: { groups: { groceries: "none" } } }

    assert_redirected_to new_session_path
  end

  test "the section lists every mappable group with its automatic and stored choice" do
    MccCategoryMapping.create!(family: @family, group_key: "taxi", disabled: true)
    MccCategoryMapping.create!(family: @family, group_key: "rent", category: @category)

    html = ApplicationController.render(partial: "settings/mcc_mappings/section", locals: { family: @family })
    page = Nokogiri::HTML5.fragment(html)
    form = page.at_css("form[action='#{settings_mcc_mapping_path}']")

    assert form
    assert_equal "_top", form["data-turbo-frame"]
    assert_equal Mcc::Taxonomy.mappable_keys.sort,
                 form.css("select").map { |select| select["name"][/\[groups\]\[(\w+)\]/, 1] }.sort
    assert_nil form.at_css("select[name='mcc_mapping[groups][own_transfer]']")

    taxi = form.at_css("select[name='mcc_mapping[groups][taxi]'] option[selected]")
    assert_equal "none", taxi["value"]

    rent = form.at_css("select[name='mcc_mapping[groups][rent]'] option[selected]")
    assert_equal @category.id, rent["value"]

    # dylan_family has a "Restaurants" subcategory, so eating out is matched by name
    eating_out = form.at_css("select[name='mcc_mapping[groups][eating_out]'] option[value='']")
    assert_equal I18n.t("settings.mcc_mappings.section.automatic", category: "Restaurants"), eating_out.text
    assert_equal "", form.at_css("select[name='mcc_mapping[groups][eating_out]'] option[selected]")["value"]

    cash = form.at_css("select[name='mcc_mapping[groups][cash_withdrawal]'] option[value='']")
    assert_equal I18n.t("settings.mcc_mappings.section.automatic_skip"), cash.text

    assert_includes html, I18n.t("settings.mcc_mappings.section.toggle", count: Mcc::Taxonomy.mappable_keys.size, changed: 2)
    assert_includes form.css("select[name='mcc_mapping[groups][rent]'] option").map(&:text), "Food & Drink › Restaurants"
  end
end
