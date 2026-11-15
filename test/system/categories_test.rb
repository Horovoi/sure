require "application_system_test_case"

class CategoriesTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
  end

  test "can create category" do
    visit categories_url
    click_link I18n.t("categories.new.new_category")
    fill_in "Name", with: "My Shiny New Category"
    click_button "Create Category"

    # The create redirects back to the list. Visiting it again here raced the request
    # and could leave before the category was saved.
    assert_text "My Shiny New Category"
  end

  test "trying to create a duplicate category fails" do
    visit categories_url
    click_link I18n.t("categories.new.new_category")
    fill_in "Name", with: categories(:food_and_drink).name
    click_button "Create Category"

    assert_text "Name has already been taken"
  end

  test "searches an icon in the category form and saves it" do
    visit categories_url
    click_link I18n.t("categories.new.new_category")
    fill_in I18n.t("categories.form.name_label"), with: "Pocket money"

    find("summary[aria-label='#{I18n.t("categories.form.trigger_label")}']").click

    search = find("input[type='search'][placeholder='#{I18n.t("ds.icon_picker.search_placeholder")}']")
    search.fill_in with: "dollar sign"
    assert_selector "label[data-filter-name^='circle-dollar-sign ']"
    assert_no_selector "label[data-filter-name='pizza']"

    # Enter in the search field filters; it does not submit the form.
    search.send_keys :enter
    assert_selector "label[data-filter-name^='circle-dollar-sign ']"

    search.fill_in with: "no-such-icon"
    assert_text I18n.t("ds.icon_picker.no_matching_icons")

    search.fill_in with: "piggy"
    find("label[data-filter-name^='piggy-bank ']").click

    click_button "Create Category"
    assert_text "Pocket money"

    assert_equal "piggy-bank", @user.family.categories.find_by!(name: "Pocket money").lucide_icon
  end
end
