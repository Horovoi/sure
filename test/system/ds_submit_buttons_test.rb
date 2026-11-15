require "application_system_test_case"

# DS::Button renders type="button" unless asked for submit. These forms submit
# through a DS::Button, so each one has to pass type: :submit or stop working.
class DsSubmitButtonsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
  end

  test "the confirm dialog's Confirm button confirms a turbo_confirm deletion" do
    visit categories_url
    assert_text categories(:food_and_drink).name

    find("[data-controller='DS--menu'] button[data-ds--menu-target='button']", match: :first).click
    click_button "Delete all"

    within "#confirm-dialog" do
      click_button "Delete All Categories"
    end

    assert_text "All categories deleted"
    assert_equal 0, @user.family.categories.reload.count
  end

  test "deleting a category in use submits the deletion form" do
    category = categories(:food_and_drink)
    visit new_category_deletion_url(category)

    click_button I18n.t("category.deletions.new.delete_and_leave_uncategorized", category_name: category.name)

    assert_text I18n.t("category.deletions.create.success")
    assert_not Category.exists?(category.id)
  end

  test "profile Save submits the profile form" do
    visit settings_profile_url

    within "form[action='#{user_path(@user)}']", match: :first do
      fill_in "First Name", with: "Robert"
      click_button I18n.t("settings.profiles.show.save")
    end

    assert_text I18n.t("users.update.success")
    assert_equal "Robert", @user.reload.first_name
  end

  test "merchant merge submits the merge form" do
    target = merchants(:amazon)
    source = merchants(:starbucks)
    visit merge_family_merchants_url

    select target.name, from: I18n.t("family_merchants.merge.target_label")
    check source.name
    click_button I18n.t("family_merchants.merge.submit")

    assert_text I18n.t("family_merchants.perform_merge.success", count: 1)
    assert_not Merchant.exists?(source.id)
  end

  test "bulk update Save submits once with the selected transactions" do
    entry = @user.family.entries.transactions.reverse_chronological.first
    visit transactions_url

    find("#" + dom_id(entry, "selection")).check
    within "#entry-selection-bar" do
      find("a[title='Edit']").click
    end

    within "#bulk_transaction_edit_drawer" do
      fill_in "Notes", with: "Bulk note"
      click_button "Save"
    end

    assert_text "1 transactions updated"
    assert_equal "Bulk note", entry.reload.notes
  end
end
