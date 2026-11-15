require "application_system_test_case"

# The new-transaction form's name autocomplete: past names, each with the
# category used most often for it. A category the user picked wins.
class TransactionNameSuggestionsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "picking a past name fills the name and its usual category" do
    visit new_transaction_url(account_id: accounts(:depository).id)

    select_starbucks
    assert_category categories(:food_and_drink)

    # The name can still be changed freely; the picked category stays
    fill_in "entry_name", with: "My custom coffee"
    fill_in "entry[amount]", with: "12.34"
    click_button I18n.t("transactions.form.submit")

    assert_text I18n.t("transactions.create.success")
    entry = @user.family.entries.order(created_at: :desc).first
    assert_equal "My custom coffee", entry.name
    assert_equal categories(:food_and_drink), entry.transaction.category
  end

  test "a manual category pick wins over a later name suggestion" do
    visit new_transaction_url(account_id: accounts(:depository).id)

    choose_category categories(:subscriptions)
    select_starbucks

    assert_category categories(:subscriptions)
  end

  test "a manual pick of no category also wins" do
    visit new_transaction_url(account_id: accounts(:depository).id)

    select_starbucks
    assert_category categories(:food_and_drink)

    choose_category nil
    select_starbucks
    assert_category nil
  end

  test "a duplicated transaction's category is not overwritten" do
    source = entries(:transaction)
    source.transaction.update!(category: categories(:subscriptions))

    visit new_transaction_url(duplicate_entry_id: source.id)
    assert_category categories(:subscriptions)

    select_starbucks
    assert_category categories(:subscriptions)
  end

  test "the name stays required" do
    visit new_transaction_url(account_id: accounts(:depository).id)

    assert_selector "#entry_name[required]"
  end

  private
    def select_starbucks
      fill_in "entry_name", with: "Starb"
      find(".hw-combobox [role='option']", text: "Starbucks").click
      assert_field "entry_name", with: "Starbucks"
    end

    def choose_category(category)
      find("[data-category-select-target='button']").click
      find("[data-category-select-target='option'][data-category-id='#{category&.id}']", match: :first).click
    end

    def assert_category(category)
      assert_selector "[data-category-select-target='hiddenInput'][value='#{category&.id}']", visible: :all
    end
end
