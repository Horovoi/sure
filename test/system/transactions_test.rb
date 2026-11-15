require "application_system_test_case"

class TransactionsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    Entry.delete_all # clean slate

    create_transaction("one", 12.days.ago.to_date, 100)
    create_transaction("two", 10.days.ago.to_date, 100)
    create_transaction("three", 9.days.ago.to_date, 100)
    create_transaction("four", 8.days.ago.to_date, 100)
    create_transaction("five", 7.days.ago.to_date, 100)
    create_transaction("six", 7.days.ago.to_date, 100)
    create_transaction("seven", 4.days.ago.to_date, 100)
    create_transaction("eight", 3.days.ago.to_date, 100)
    create_transaction("nine", 1.days.ago.to_date, 100)
    @uncategorized_transaction = create_transaction("ten", 1.days.ago.to_date, 100)
    create_transaction("eleven", Date.current, 100, category: categories(:food_and_drink), tags: [ tags(:one) ], merchant: merchants(:amazon))

    @transactions = @user.family.entries
                         .transactions
                         .reverse_chronological

    @transaction = @transactions.first

    @page_size = 10

    visit transactions_url(per_page: @page_size)
  end

  test "can search for a transaction" do
    assert_selector "h1", text: "Transactions"

    within "form#transactions-search" do
      fill_in "Search transactions ...", with: @transaction.name
      find("#q_search").send_keys(:tab) # Trigger blur to submit form
    end

    assert_selector "#" + dom_id(@transaction), count: 1

    within "#transaction-search-filters" do
      assert_text @transaction.name
    end
  end

  test "can open filters and apply one or more" do
    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      check(@transaction.account.name)
      click_button "Category"
      check(@transaction.transaction.category.name)
      click_button "Apply"
    end

    assert_selector "#" + dom_id(@transaction), count: 1

    within "#transaction-search-filters" do
      assert_text @transaction.account.name
      assert_text @transaction.transaction.category.name
    end
  end

  test "can filter uncategorized transactions" do
    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      click_button "Category"
      check("Uncategorized")
      click_button "Apply"
    end

    assert_selector "#" + dom_id(@uncategorized_transaction), count: 1
    assert_no_selector("#" + dom_id(@transaction))

    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      click_button "Category"
      check(@transaction.transaction.category.name)
      click_button "Apply"
    end

    assert_selector "#" + dom_id(@transaction), count: 1
    assert_selector "#" + dom_id(@uncategorized_transaction), count: 1
  end

  test "all filters work and empty state shows if no match" do
    find("#transaction-filters-button").click

    account = @transaction.account
    category = @transaction.transaction.category
    merchant = @transaction.transaction.merchant

    within "#transaction-filters-menu" do
      click_button "Account"
      check(account.name)

      click_button "Date"
      fill_in "q_start_date", with: 10.days.ago.to_date
      fill_in "q_end_date", with: 1.day.ago.to_date

      click_button "Type"
      check("Income")

      click_button "Amount"
      select "Less than"
      fill_in "q_amount", with: 200

      click_button "Category"
      check(category.name)

      click_button "Merchant"
      check(merchant.name)

      click_button "Apply"
    end

    assert_text "No entries found"

    # Remove all filters by clicking their X buttons
    # Get all the filter buttons at once to avoid stale elements
    filter_count = page.all("ul#transaction-search-filters li button").count

    # Click each one with a small delay to let Turbo update
    filter_count.times do
      page.all("ul#transaction-search-filters li button").first.click
      sleep 0.1
    end

    assert_text @transaction.name
  end

  test "clear all clears all filters in one click" do
    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      click_button "Date"
      fill_in "q_start_date", with: 10.days.ago.to_date
      fill_in "q_end_date", with: 1.day.ago.to_date

      click_button "Type"
      check("Income")

      click_button "Category"
      check(@transaction.transaction.category.name)

      click_button "Apply"
    end

    assert_text "No entries found"

    within find("ul#transaction-search-filters").find(:xpath, "..") do
      click_on "Clear all"
    end

    assert_text @transaction.name
    assert_no_text "No entries found"
    assert_selector "#total-transactions", text: @user.family.entries.transactions.count.to_s
  end

  test "can select and deselect entire page of transactions" do
    all_transactions_checkbox.check
    assert_selection_count(number_of_transactions_on_page)
    all_transactions_checkbox.uncheck
    assert_selection_count(0)
  end

  test "searching drops selected transactions that are no longer shown" do
    hidden_after_search = @transactions.first
    still_shown = @transactions.find { |entry| entry.name == "two" }

    transaction_checkbox(hidden_after_search).check
    assert_selection_count(1)

    # Narrow the list so the selected row is no longer on screen
    search_for("two")
    assert_no_selector "#" + dom_id(hidden_after_search)
    assert_selection_count(0)

    # Selecting a visible row must not carry the hidden one along
    transaction_checkbox(still_shown).check
    assert_selection_count(1)

    # A row that stays visible keeps its selection across a search
    search_for("tw")
    assert_selector "#" + dom_id(still_shown)
    assert_selection_count(1)
    assert transaction_checkbox(still_shown).checked?
  end

  test "changing page drops the selection of the previous page" do
    all_transactions_checkbox.check
    assert_selection_count(number_of_transactions_on_page)

    within "#transactions_results nav" do
      find("a", exact_text: "2").click
    end
    assert_no_selector "#" + dom_id(@transactions.first)

    assert_selection_count(0)
    transaction_checkbox(@transactions.last).check
    assert_selection_count(1)
  end

  test "can select and deselect groups of transactions" do
    date_transactions_checkbox(1.day.ago.to_date).check
    assert_selection_count(2)

    date_transactions_checkbox(1.day.ago.to_date).uncheck
    assert_selection_count(0)
  end

  test "can select and deselect individual transactions" do
    transaction_checkbox(@transactions.first).check
    assert_selection_count(1)
    transaction_checkbox(@transactions.second).check
    assert_selection_count(2)
    transaction_checkbox(@transactions.second).uncheck
    assert_selection_count(1)
  end

  test "outermost group always overrides inner selections" do
    transaction_checkbox(@transactions.first).check
    assert_selection_count(1)

    all_transactions_checkbox.check
    assert_selection_count(number_of_transactions_on_page)

    transaction_checkbox(@transactions.first).uncheck
    assert_selection_count(number_of_transactions_on_page - 1)

    date_transactions_checkbox(1.day.ago.to_date).uncheck
    assert_selection_count(number_of_transactions_on_page - 3)

    all_transactions_checkbox.uncheck
    assert_selection_count(0)
  end


  test "can create deposit transaction for investment account" do
    investment_account = accounts(:investment)
    investment_account.entries.create!(name: "Investment account", date: Date.current, amount: 1000, currency: "USD", entryable: Transaction.new)
    transfer_date = Date.current
    visit account_url(investment_account, tab: "activity")
    within "[data-testid='activity-menu']" do
      click_on "New"
      click_on "New activity"
    end
    select "Deposit", from: "Type"
    fill_in "Date", with: transfer_date
    fill_in "model[amount]", with: 175.25
    click_button "Add transaction"
    within "#" + dom_id(investment_account, "entries_#{transfer_date}") do
      assert_text "175.25"
    end
  end

  test "transfers should always sum to zero" do
    # Between two cash accounts: a transfer into an investment account is an investment
    # contribution, which counts as spending
    asset_account = accounts(:other_asset)
    cash_account = accounts(:depository)
    outflow_entry = create_transaction("outflow", Date.current, 500, account: asset_account)
    inflow_entry = create_transaction("inflow", 1.day.ago.to_date, -500, account: cash_account)
    @user.family.auto_match_transfers!
    # An auto-match is only a suggestion until confirmed
    outflow_entry.transaction.reload.transfer.confirm!
    visit transactions_url

    within "#entry-group-" + Date.current.to_s + "-totals" do
      assert_text "-$100.00" # transaction eleven from setup
    end
  end

  test "a transfer into an investment account counts as spending" do
    outflow_entry = create_transaction("outflow", Date.current, 500, account: accounts(:other_asset))
    inflow_entry = create_transaction("inflow", 1.day.ago.to_date, -500, account: accounts(:investment))
    @user.family.auto_match_transfers!
    # An auto-match is only a suggestion until confirmed
    outflow_entry.transaction.reload.transfer.confirm!
    assert outflow_entry.transaction.reload.investment_contribution?
    visit transactions_url

    within "#entry-group-" + Date.current.to_s + "-totals" do
      assert_text "-$600.00" # the contribution plus transaction eleven from setup
    end
  end

  test "the drawer disables Mark as recurring for a transaction that is already recurring" do
    entry = @user.family.entries.find_by!(name: "eleven")
    @user.family.recurring_transactions.create!(
      merchant: merchants(:amazon), amount: entry.amount, currency: entry.currency,
      expected_day_of_month: entry.date.day, last_occurrence_date: entry.date,
      next_expected_date: 1.month.from_now.to_date, status: "active", manual: true, occurrence_count: 1
    )

    open_settings_in_drawer(entry)

    within_testid("mark-recurring") do
      assert_selector "button[disabled]", text: I18n.t("transactions.mark_recurring.already_button")
      assert_link I18n.t("transactions.mark_recurring.view"), href: subscriptions_path(kind: "other")
    end
  end

  test "the drawer offers Mark as recurring for a transaction with no recurring row" do
    open_settings_in_drawer(@user.family.entries.find_by!(name: "ten"))

    within_testid("mark-recurring") do
      assert_selector "button:not([disabled])", text: I18n.t("transactions.mark_recurring.button")
      assert_no_selector "[data-testid='mark-recurring-link']"
    end
  end

  test "a subscription match is merged into the real charge and restored again" do
    account = accounts(:depository)
    recurring = @user.family.recurring_transactions.create!(
      name: "Streaming club", amount: 20, currency: "USD", expected_day_of_month: Date.current.day,
      last_occurrence_date: Date.current, next_expected_date: Date.current.next_month,
      status: "active", subscription_state: "subscription", default_account: account
    )
    generated = account.entries.create!(
      date: Date.current, amount: 20, currency: "USD", name: "Streaming club", source: "subscription",
      entryable: Transaction.new(category: categories(:subscriptions), recurring_transaction: recurring)
    )
    real = account.entries.create!(date: Date.current, amount: 23, currency: "USD", name: "STREAMING CLUB PAYMENT", entryable: Transaction.new)
    generated.transaction.flag_potential_duplicate!(posted_entry: real, reason: "subscription_charge", posted_amount: real.amount)

    visit transactions_url(per_page: @page_size)

    within "#" + dom_id(generated) do
      assert_selector "[data-testid='subscription-match-badge']", text: I18n.t("transactions.subscription_match_badge.label")
      click_link generated.name, exact: true
    end

    assert_text I18n.t("transactions.subscription_match.potential_duplicate_title")
    click_button I18n.t("transactions.show.merge_duplicate")

    assert_text I18n.t("transactions.merge_duplicate.success")
    assert_no_selector "#" + dom_id(generated)
    assert_equal recurring.id, real.reload.transaction.recurring_transaction_id

    within "#" + dom_id(real) do
      click_link real.name, exact: true
    end

    within_testid("replaced-subscription-charge") do
      assert_text I18n.t("transactions.replaced_subscription_charge.title", date: I18n.l(Date.current, format: :long))
      click_button I18n.t("transactions.replaced_subscription_charge.restore")
    end

    assert_text I18n.t("transactions.restore_subscription_charge.success")
    restored = account.entries.find_by!(source: "subscription", name: "Streaming club")
    assert_selector "#" + dom_id(restored)
    assert_nil real.reload.transaction.recurring_transaction_id
  end

  def open_settings_in_drawer(entry)
    within "#" + dom_id(entry) do
      click_link entry.name, exact: true
    end
    # Section titles render uppercase (CSS), and the browser reports the rendered text
    find("summary", text: /\A#{Regexp.escape(I18n.t("transactions.show.settings"))}\z/i).click
  end

  private

    def create_transaction(name, date, amount, category: nil, merchant: nil, tags: [], account: nil)
      account ||= accounts(:depository)

      account.entries.create! \
        name: name,
        date: date,
        amount: amount,
        currency: "USD",
        entryable: Transaction.new(category: category, merchant: merchant, tags: tags)
    end

    def number_of_transactions_on_page
      [ @user.family.entries.count, @page_size ].min
    end

    def all_transactions_checkbox
      find("#selection_entry")
    end

    def date_transactions_checkbox(date)
      find("#selection_entry_#{date}")
    end

    def search_for(text)
      within "form#transactions-search" do
        fill_in "Search transactions ...", with: text
        find("#q_search").send_keys(:tab) # Trigger blur to submit form
      end
    end

    def transaction_checkbox(transaction)
      find("#" + dom_id(transaction, "selection"))
    end

    def assert_selection_count(count)
      if count == 0
        assert_no_selector("#entry-selection-bar")
      else
        within "#entry-selection-bar" do
          assert_text "#{count} transaction#{count == 1 ? "" : "s"} selected"
        end
      end
    end
end
