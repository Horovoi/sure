require "application_system_test_case"

# The DS pickers of the transaction form and drawer: searchable, hierarchical,
# with recent categories and inline create of categories, merchants and tags.
class TransactionCategorySelectTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "creates an income subcategory inline from an income transaction" do
    salary = @family.categories.create!(name: "Salary", color: "#22c55e", classification: "income", lucide_icon: "briefcase")

    visit new_transaction_url(nature: "inflow")

    assert_difference "Category.count", +1 do
      within "[data-controller='category-select']" do
        find("button[data-category-select-target='button']").click
        fill_in I18n.t("ds.category_select.search_placeholder"), with: "Bonus"
        click_button I18n.t("ds.category_select.create_as_subcategory")

        assert_text I18n.t("ds.category_select.choose_parent", name: "Bonus")
        # Only income parents are offered on an income transaction.
        assert_no_selector "button[data-parent-id='#{categories(:food_and_drink).id}']"
        find("button[data-parent-id='#{salary.id}']").click

        assert_selector "[data-category-select-target='selectionContainer']", text: "Bonus"
      end
    end

    bonus = Category.find_by!(name: "Bonus")
    assert_equal salary, bonus.parent
    assert_equal "income", bonus.classification
  end

  test "creates a top-level category with the form's classification and saves it on the transaction" do
    visit new_transaction_url(nature: "inflow")

    fill_in "entry_name", with: "Side gig"
    fill_in "entry[amount]", with: "250"
    select accounts(:depository).name, from: "entry[account_id]"

    within "[data-controller='category-select']" do
      find("button[data-category-select-target='button']").click
      fill_in I18n.t("ds.category_select.search_placeholder"), with: "Freelance"
      click_button I18n.t("ds.category_select.create", name: "Freelance")
      # The create is a background request; the picker shows the category once it is saved
      assert_selector "[data-category-select-target='selectionContainer']", text: "Freelance"
    end

    freelance = Category.find_by!(name: "Freelance")
    assert_equal "income", freelance.classification

    click_button I18n.t("transactions.form.submit")

    assert_text "Transaction created"
    entry = Entry.order(:created_at).last
    assert_equal freelance, entry.transaction.category
  end

  test "recent categories show above the list until a search is typed" do
    recent = categories(:subscriptions)
    recent.update!(last_used_at: 1.minute.ago)

    visit new_transaction_url

    within "[data-controller='category-select']" do
      find("button[data-category-select-target='button']").click
      assert_selector "[data-category-select-target='recentSection'] [data-category-id='#{recent.id}']"

      fill_in I18n.t("ds.category_select.search_placeholder"), with: "Food"
      assert_no_selector "[data-category-select-target='recentSection']"
    end
  end

  test "Enter in the tag search creates the tag without submitting the form" do
    visit new_transaction_url
    open_section I18n.t("transactions.form.details")

    assert_no_difference "Entry.count" do
      within "[data-controller='tag-select']" do
        find("button[data-tag-select-target='button']").click
        find("input[type=search]").fill_in with: "Trip 2026"
        find("input[type=search]").send_keys :enter

        assert_selector "[data-tag-select-target='selectionContainer']", text: "Trip 2026"
      end
    end

    assert Tag.exists?(name: "Trip 2026", family: @family)
  end

  test "creates a merchant inline from the transaction drawer" do
    entry = entries(:transaction)

    visit transactions_url
    page.execute_script <<~JS
      document.querySelector("turbo-frame#drawer").src = "#{transaction_url(entry)}"
    JS

    within "turbo-frame#drawer", visible: :all do
      open_section I18n.t("transactions.show.details")

      within "[data-controller='merchant-select']" do
        find("button[data-merchant-select-target='button']").click
        find("input[type=search]").fill_in with: "Corner Bakery"
        click_button I18n.t("ds.merchant_select.create_html", name: "Corner Bakery")
        # The create is a background request; the picker shows the merchant once it is saved
        assert_selector "button[data-merchant-select-target='button']", text: "Corner Bakery"
      end
    end

    merchant = FamilyMerchant.find_by!(name: "Corner Bakery", family: @family)
    assert_selector "##{ActionView::RecordIdentifier.dom_id(entry)}", text: "Corner Bakery"
    assert_equal merchant, entry.transaction.reload.merchant
  end

  test "creates a category from the list's quick picker with the transaction's nature" do
    transaction = transactions(:one)
    transaction.entry.update!(amount: -40)

    visit transactions_url

    within "##{ActionView::RecordIdentifier.dom_id(transaction, :category_menu_desktop)}" do
      find("button[data-ds--popover-target='button']").click
    end

    within "turbo-frame#category_dropdown" do
      find("input[type=search]").fill_in with: "Refunds"
      click_button I18n.t("category.dropdowns.show.create", name: "Refunds")
    end

    # The row's own button, which the server redraws after the save (the open picker
    # already shows the name while the request runs)
    assert_selector "##{ActionView::RecordIdentifier.dom_id(transaction, :category_menu_desktop)} button[data-ds--popover-target='button']", text: "Refunds"
    refunds = Category.find_by!(name: "Refunds")
    assert_equal "income", refunds.classification
    assert_equal refunds, transaction.reload.category
  end

  test "toggles a tag from the transaction row" do
    entry = entries(:transaction)
    tag = @family.tags.alphabetically.first
    entry.transaction.update!(tag_ids: [])

    visit transactions_url

    row = find("##{ActionView::RecordIdentifier.dom_id(entry)}")
    row.hover
    within row do
      find("#" + ActionView::RecordIdentifier.dom_id(entry.transaction, :tag_summary_desktop)).click
    end

    within "turbo-frame#tag_dropdown" do
      find("##{ActionView::RecordIdentifier.dom_id(entry, :tag_option)}_#{tag.id} button").click
      assert_selector "##{ActionView::RecordIdentifier.dom_id(entry, :tag_option)}_#{tag.id}[aria-selected='true']"
    end

    assert_selector "##{ActionView::RecordIdentifier.dom_id(entry.transaction, :tag_summary_desktop)}", text: tag.name
    assert_equal [ tag.id ], entry.transaction.reload.tag_ids
  end

  private
    # Form and drawer sections start closed; their titles render uppercase (CSS)
    def open_section(title)
      find("summary", text: /\A#{Regexp.escape(title)}\z/i).click
    end
end
