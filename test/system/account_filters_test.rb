require "application_system_test_case"

class AccountFiltersTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    @account = @user.family.accounts.create!(
      name: "[system test] Filter account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    @food_category = categories(:subcategory)
    @shopping_category = @user.family.categories.create!(
      name: "Shopping test",
      color: "#2563eb",
      lucide_icon: "shopping-cart",
      classification: "expense"
    )
    @income_category = categories(:income)

    @matching_expense = create_transaction("Matching expense", 100, @food_category)
    @other_expense = create_transaction("Other expense", 80, @shopping_category)
    @income_entry = create_transaction("Income entry", -120, @income_category)

    visit account_url(@account, tab: "activity", chart_view: "balance", per_page: 50)
  end

  test "account page advanced filters work end to end" do
    find("#activity-filter-button").click

    within "#transaction-filters-menu" do
      assert_button "Date"
      assert_button "Type"
      assert_button "Status"
      assert_button "Amount"
      assert_button "Category"
      assert_button "Tag"
      assert_button "Merchant"
      assert_no_button "Account"

      click_button "Type"
      check "Expense"

      click_button "Category"
      check @food_category.name
    end

    page.execute_script("document.getElementById('entries-search').requestSubmit()")

    assert_text @matching_expense.name
    assert_no_text @other_expense.name
    assert_no_text @income_entry.name

    within "ul#transaction-search-filters" do
      within find("li", text: @food_category.name) do
        find("button").click
      end
    end

    assert_text @matching_expense.name
    assert_text @other_expense.name
    assert_no_text @income_entry.name

    within find("ul#transaction-search-filters").find(:xpath, "..") do
      click_on "Clear all"
    end

    assert_text @matching_expense.name
    assert_text @other_expense.name
    assert_text @income_entry.name
  end

  test "account page clear all clears all filters in one click" do
    find("#activity-filter-button").click

    within "#transaction-filters-menu" do
      click_button "Type"
      check "Expense"

      click_button "Category"
      check @food_category.name
    end

    page.execute_script("document.getElementById('entries-search').requestSubmit()")

    assert_text @matching_expense.name
    assert_no_text @other_expense.name
    assert_no_text @income_entry.name

    within find("ul#transaction-search-filters").find(:xpath, "..") do
      click_on "Clear all"
    end

    assert_text @matching_expense.name
    assert_text @other_expense.name
    assert_text @income_entry.name
  end

  test "account page filters by No merchant and Untagged" do
    @matching_expense.entryable.update!(merchant: merchants(:netflix))
    @other_expense.entryable.update!(tags: [ tags(:one) ])

    find("#activity-filter-button").click

    within "#transaction-filters-menu" do
      click_button "Merchant"
      check "No merchant"
    end

    page.execute_script("document.getElementById('entries-search').requestSubmit()")

    assert_no_text @matching_expense.name
    assert_text @other_expense.name
    assert_text @income_entry.name

    within "ul#transaction-search-filters" do
      assert_text "No merchant"
      assert_no_text Merchant::NO_MERCHANT_FILTER_VALUE
    end

    within find("ul#transaction-search-filters").find(:xpath, "..") do
      click_on "Clear all"
    end
    # Wait for the cleared page, or the next filter goes into the old page's form
    assert_no_selector "ul#transaction-search-filters"

    find("#activity-filter-button").click

    within "#transaction-filters-menu" do
      click_button "Tag"
      check "Untagged"
    end

    page.execute_script("document.getElementById('entries-search').requestSubmit()")

    assert_text @matching_expense.name
    assert_no_text @other_expense.name
    assert_text @income_entry.name

    within "ul#transaction-search-filters" do
      assert_text "Untagged"
    end
  end

  private

    def create_transaction(name, amount, category)
      @account.entries.create!(
        name: "[system test] #{name}",
        date: Date.current,
        amount: amount,
        currency: "USD",
        entryable: Transaction.new(category: category)
      )
    end
end
