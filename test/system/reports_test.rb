require "application_system_test_case"

class ReportsTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = @family.accounts.create!(name: "Reports checking", currency: @family.currency, balance: 0, accountable: Depository.new)
    @category = @family.categories.create!(name: "Reports Groceries", classification: "expense", color: "#123456")
    create_transaction(account: @account, currency: @family.currency, category: @category, amount: 42, name: "Corner shop", date: Date.current)
    create_transaction(account: @account, currency: @family.currency, amount: 17, name: "Loose receipt", date: Date.current)
    sign_in @user
  end

  test "a breakdown category row opens its filtered transactions" do
    visit_breakdown

    within "[data-category='category-#{@category.id}']" do
      click_link "Reports Groceries"
    end

    assert_current_path(/\/transactions/)
    assert_text "Corner shop"
    assert_no_text "Loose receipt"
  end

  test "the uncategorized breakdown row opens the uncategorized transactions" do
    visit_breakdown

    within "[data-category='category-uncategorized'][class*='group/category-row']", match: :first do
      click_link Category.uncategorized_name
    end

    assert_current_path(/\/transactions/)
    assert_text "Loose receipt"
    assert_no_text "Corner shop"
  end

  private
    def visit_breakdown
      visit reports_path(period_type: :custom, start_date: 30.days.ago.to_date, end_date: Date.current)

      # The category table sits in a closed <details> under the expense treemap
      within "[data-section-key='transactions_breakdown']" do
        all("summary", text: /View category details/).each(&:click)
      end
    end
end
