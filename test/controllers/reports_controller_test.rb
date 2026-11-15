require "test_helper"

class ReportsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "index renders successfully" do
    get reports_path
    assert_response :ok
  end

  test "index with monthly period" do
    get reports_path(period_type: :monthly)
    assert_response :ok
    assert_select "h1", text: I18n.t("reports.index.title")
  end

  test "index with quarterly period" do
    get reports_path(period_type: :quarterly)
    assert_response :ok
  end

  test "index with ytd period" do
    get reports_path(period_type: :ytd)
    assert_response :ok
  end

  test "index with custom period and date range" do
    get reports_path(
      period_type: :custom,
      start_date: 1.month.ago.to_date.to_s,
      end_date: Date.current.to_s
    )
    assert_response :ok
  end

  test "index with last 6 months period" do
    get reports_path(period_type: :last_6_months)
    assert_response :ok
  end

  test "index shows empty state when no transactions" do
    # Delete all transactions for the family by deleting from accounts
    @family.accounts.each { |account| account.entries.destroy_all }

    get reports_path
    assert_response :ok
    assert_select "h3", text: I18n.t("reports.empty_state.title")
  end

  test "index with budget performance for current month" do
    # Create a budget for current month
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current.beginning_of_month)
    category = @family.categories.expenses.first

    # Fail fast if test setup is incomplete
    assert_not_nil category, "Test setup failed: no expense category found for family"
    assert_not_nil budget, "Test setup failed: budget could not be created or found"

    # Find or create budget category to avoid duplicate errors
    budget_category = budget.budget_categories.find_or_initialize_by(category: category)
    budget_category.budgeted_spending = Money.new(50000, @family.currency)
    budget_category.save!

    get reports_path(period_type: :monthly)
    assert_response :ok
  end

  test "budget performance uses the current fiscal budget and its budgeted amount" do
    travel_to Date.new(2026, 3, 20) do
      @family.update!(use_fiscal_months: true, fiscal_month_start_day: 10)
      budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
      assert_equal Date.new(2026, 3, 10), budget.start_date

      budget.update!(budgeted_spending: 1000)
      budget.budget_categories.find_by!(category: categories(:food_and_drink)).update!(budgeted_spending: 400)
      create_transaction(account: accounts(:depository), date: Date.new(2026, 3, 12), amount: 250, category: categories(:food_and_drink))

      get reports_path(period_type: :monthly, fiscal_mode: "true")
      assert_response :ok

      metrics = controller.instance_variable_get(:@summary_metrics)
      assert_equal 25.0, metrics[:budget_percent]
    end
  end

  test "budget performance never creates a budget on a page view" do
    @family.budgets.destroy_all

    assert_no_difference -> { Budget.count } do
      get reports_path(period_type: :monthly)
    end
    assert_response :ok
    assert_equal 0, controller.instance_variable_get(:@summary_metrics)[:budget_percent]
  end

  test "index calculates summary metrics correctly" do
    get reports_path(period_type: :monthly)
    assert_response :ok
    assert_select "h3", text: I18n.t("reports.summary.total_income")
    assert_select "h3", text: I18n.t("reports.summary.total_expenses")
    assert_select "h3", text: I18n.t("reports.summary.net_savings")
  end

  test "index builds trends data" do
    get reports_path(period_type: :monthly)
    assert_response :ok
    assert_select "h2", text: I18n.t("reports.trends.title")
    assert_select '[role="columnheader"]' do
      assert_select "div", text: I18n.t("reports.trends.month")
    end
  end

  test "index handles invalid date parameters gracefully" do
    get reports_path(
      period_type: :custom,
      start_date: "invalid-date",
      end_date: "also-invalid"
    )
    assert_response :ok # Should not crash, uses defaults
  end

  test "index swaps dates when end_date is before start_date" do
    start_date = Date.current
    end_date = 1.month.ago.to_date

    get reports_path(
      period_type: :custom,
      start_date: start_date.to_s,
      end_date: end_date.to_s
    )

    assert_response :ok
    # Should show flash message about invalid date range
    assert_match /End date cannot be before start date/, flash[:alert]
  end

  test "spending patterns returns data when expense transactions exist" do
    # Create expense category
    expense_category = @family.categories.create!(
      name: "Test Groceries",
      classification: "expense"
    )

    # Create account
    account = @family.accounts.first

    # Create expense transaction on a weekday (Monday)
    weekday_date = Date.current.beginning_of_month + 2.days
    weekday_date = weekday_date.next_occurring(:monday)

    entry = account.entries.create!(
      name: "Grocery shopping",
      date: weekday_date,
      amount: 50.00,
      currency: "USD",
      entryable: Transaction.new(
        category: expense_category,
        kind: "standard"
      )
    )

    # Create expense transaction on a weekend (Saturday)
    weekend_date = weekday_date.next_occurring(:saturday)

    weekend_entry = account.entries.create!(
      name: "Weekend shopping",
      date: weekend_date,
      amount: 75.00,
      currency: "USD",
      entryable: Transaction.new(
        category: expense_category,
        kind: "standard"
      )
    )

    get reports_path(period_type: :monthly)
    assert_response :ok

    # Verify spending patterns shows data (not the "no data" message)
    assert_select ".text-center.py-8.text-subdued", { text: /No spending data/, count: 0 }, "Should not show 'No spending data' message when transactions exist"
  end

  test "export transactions with API key authentication" do
    # Use an active API key with read permissions
    api_key = api_keys(:active_key)

    # Make sure the API key has the correct source
    api_key.update!(source: "web") unless api_key.source == "web"

    get export_transactions_reports_path(
      format: :csv,
      period_type: :ytd,
      start_date: Date.current.beginning_of_year,
      end_date: Date.current,
      api_key: api_key.plain_key
    )

    assert_response :ok
    assert_equal "text/csv", @response.media_type
    assert_match /Category/, @response.body
  end

  test "export with an API key neither creates nor reuses a browser session" do
    api_key = api_keys(:active_key)
    Session.where(user: api_key.user).delete_all

    assert_no_difference -> { Session.count } do
      get export_transactions_reports_path(format: :csv, period_type: :ytd, api_key: api_key.plain_key)
    end

    assert_response :ok
  end

  test "export transactions with invalid API key" do
    get export_transactions_reports_path(
      format: :csv,
      period_type: :ytd,
      api_key: "invalid_key"
    )

    assert_response :unauthorized
    assert_match /Invalid or expired API key/, @response.body
  end

  test "export transactions without API key uses session auth" do
    # Should use normal session-based authentication
    # The setup already signs in @user = users(:family_admin)
    assert_not_nil @user, "User should be set in test setup"
    assert_not_nil @family, "Family should be set in test setup"

    get export_transactions_reports_path(
      format: :csv,
      period_type: :ytd,
      start_date: Date.current.beginning_of_year,
      end_date: Date.current
    )

    assert_response :ok, "Export should work with session auth. Response: #{@response.body}"
    assert_equal "text/csv", @response.media_type
  end

  test "export transactions swaps dates when end_date is before start_date" do
    start_date = Date.current
    end_date = 1.month.ago.to_date

    get export_transactions_reports_path(
      format: :csv,
      period_type: :custom,
      start_date: start_date.to_s,
      end_date: end_date.to_s
    )

    assert_response :ok
    assert_equal "text/csv", @response.media_type
    # Verify the CSV content is generated (should not crash)
    assert_not_nil @response.body
  end

  test "index groups transactions by parent and subcategories" do
    # Create parent category with subcategories
    parent_category = @family.categories.create!(name: "Entertainment", classification: "expense", color: "#FF5733", lucide_icon: "film")
    subcategory_movies = @family.categories.create!(name: "Movies", classification: "expense", parent: parent_category, color: "#33FF57", lucide_icon: "film")
    subcategory_games = @family.categories.create!(name: "Games", classification: "expense", parent: parent_category, color: "#5733FF", lucide_icon: "gamepad-2")

    # Create transactions using helper
    create_transaction(account: @family.accounts.first, name: "Cinema ticket", amount: 15, category: subcategory_movies)
    create_transaction(account: @family.accounts.first, name: "Video game", amount: 60, category: subcategory_games)

    get reports_path(period_type: :monthly)
    assert_response :ok

    # Parent category
    assert_select "div[data-category='category-#{parent_category.id}']", text: /Entertainment/

    # Subcategories
    assert_select "div[data-category='category-#{subcategory_movies.id}']", text: /Movies/
    assert_select "div[data-category='category-#{subcategory_games.id}']", text: /Games/
  end

  test "index shows synthetic Other subcategory when parent has direct transactions" do
    parent_category = @family.categories.create!(name: "Housing", classification: "expense", color: "#FF5733", lucide_icon: "home")
    rent_subcategory = @family.categories.create!(name: "Rent", classification: "expense", parent: parent_category, lucide_icon: "home")

    account = @family.accounts.first

    # Direct transaction on parent category
    create_transaction(account: account, name: "Home repair", amount: 200, category: parent_category)
    # Subcategory transaction
    create_transaction(account: account, name: "Monthly rent", amount: 1500, category: rent_subcategory)

    get reports_path(period_type: :monthly)
    assert_response :ok

    # Synthetic "Other Housing" row should appear
    assert_select "div[data-category='category-#{parent_category.id}_other']", text: /Other Housing/
  end

  test "index does not show synthetic Other subcategory when parent has no direct transactions" do
    parent_category = @family.categories.create!(name: "Travel", classification: "expense", color: "#2563eb", lucide_icon: "plane")
    flights_subcategory = @family.categories.create!(name: "Flights", classification: "expense", parent: parent_category, lucide_icon: "plane")

    account = @family.accounts.first
    create_transaction(account: account, name: "Flight to NYC", amount: 400, category: flights_subcategory)

    get reports_path(period_type: :monthly)
    assert_response :ok

    # No synthetic row should appear
    assert_select "div[data-category='category-#{parent_category.id}_other']", count: 0
  end

  test "reports preferences merge collapsed sections and replace the section order" do
    patch update_preferences_reports_url, params: { preferences: { reports_collapsed_sections: { trends_insights: true } } }, as: :json
    patch update_preferences_reports_url, params: { preferences: { reports_collapsed_sections: { net_worth: true }, reports_section_order: %w[net_worth trends_insights] } }, as: :json

    assert_response :success
    preferences = @user.reload.preferences
    assert_equal({ "trends_insights" => true, "net_worth" => true }, preferences["reports_collapsed_sections"])
    assert_equal %w[net_worth trends_insights], preferences["reports_section_order"]
  end

  test "malformed reports preferences are a bad request, not an error" do
    patch update_preferences_reports_url, params: { preferences: "nope" }, as: :json

    assert_response :bad_request
  end

  # --- Exchange rate notes (w1-fx nearest-rate) ---

  test "reports warns about a currency with no exchange rate and notes a stale one" do
    family = @user.family
    family.accounts.create!(name: "PLN cash", balance: 100, currency: "PLN", accountable: Depository.new)
    family.accounts.create!(name: "EUR cash", balance: 100, currency: "EUR", accountable: Depository.new)
    ExchangeRate.create!(from_currency: "EUR", to_currency: family.currency, date: 30.days.ago.to_date, rate: 1.1)

    get reports_path

    assert_response :ok
    assert_select "[data-testid=missing-exchange-rates]", text: /No exchange rate from PLN to #{family.currency}/
    assert_select "[data-testid=stale-exchange-rates]", text: /EUR from #{Regexp.escape(I18n.l(30.days.ago.to_date, format: :long))}/
  end

  test "reports shows no exchange rate note when every currency has a current rate" do
    get reports_path

    assert_response :ok
    assert_select "[data-testid=missing-exchange-rates]", count: 0
    assert_select "[data-testid=stale-exchange-rates]", count: 0
  end

  # --- Investment performance across currencies (w1-fx securities-fx) ---

  # A UAH position sold for USD: the proceeds convert into UAH at the sale date,
  # and the gain into the family currency at the same date. 2 x 110 USD x 42 =
  # 9 240 UAH, less 8 000 UAH of basis, is 1 240 UAH, which is 31.00 at 0.025.
  # Re-labelled instead of converted, the line would read 1,240.00.
  test "investment performance includes a foreign-currency sale converted at its own date" do
    ExchangeRate.stubs(:provider).returns(nil)
    date = Date.current
    currency = @family.currency
    account = @family.accounts.create!(name: "UAH Brokerage", balance: 10_000, currency: "UAH", accountable: Investment.new)
    security = Security.create!(ticker: "UXA#{SecureRandom.hex(3)}", name: "Listed in USD")

    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: date, rate: 42)
    ExchangeRate.create!(from_currency: "UAH", to_currency: currency, date: date, rate: 0.025)
    account.holdings.create!(security: security, date: date - 1.day, qty: 10, price: 4_000,
                             amount: 40_000, currency: "UAH", cost_basis: 4_000)
    create_trade(security, account: account, qty: -2, date: date, price: 110, currency: "USD")

    get reports_path
    assert_response :ok

    line = css_select("[data-testid='realized-gain-line']").map(&:text).find { |text| text.include?(security.ticker) }
    assert line, "the sale must be listed"
    assert_match "31.00", line
    assert_no_match(/1,240\.00/, line)
    assert_select "[data-testid=unconverted-gains-note]", count: 0
  end

  test "investment performance counts a sale with no exchange rate as left out" do
    ExchangeRate.stubs(:provider).returns(nil)
    date = Date.current
    account = @family.accounts.create!(name: "UAH Brokerage", balance: 10_000, currency: "UAH", accountable: Investment.new)
    security = Security.create!(ticker: "PLX#{SecureRandom.hex(3)}", name: "Listed in PLN")

    ExchangeRate.create!(from_currency: "UAH", to_currency: @family.currency, date: date, rate: 0.025)
    account.holdings.create!(security: security, date: date - 1.day, qty: 10, price: 4_000,
                             amount: 40_000, currency: "UAH", cost_basis: 4_000)
    create_trade(security, account: account, qty: -2, date: date, price: 400, currency: "PLN")

    get reports_path
    assert_response :ok

    assert_select "[data-testid=unconverted-gains-note]", text: /1 gain is not included/
  end
end
