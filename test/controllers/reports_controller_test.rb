require "test_helper"

class ReportsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  include BalanceTestHelper

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

  test "a transfer out is not listed among the period's sales" do
    account = @family.accounts.create!(name: "Wallet", balance: 100, currency: "USD", accountable: Investment.new)
    security = Security.find_or_create_by!(ticker: "MOVE") { |sec| sec.name = "Movable" }
    Holding.create!(account: account, security: security, date: 10.days.ago.to_date,
                    qty: 100, price: 2, amount: 200, currency: "USD", cost_basis: 1)

    %w[Transfer Sell].each do |label|
      account.entries.create!(
        date: 3.days.ago.to_date, name: "out #{label}", amount: 0, currency: "USD",
        entryable: Trade.new(security: security, qty: -40, price: 3, currency: "USD", investment_activity_label: label)
      )
    end

    get reports_path(period_type: :custom, start_date: 30.days.ago.to_date, end_date: Date.current)
    assert_response :success

    assert_match I18n.t("reports.investment_performance.sells_count", count: 1), response.body
    assert_no_match(/#{Regexp.escape(I18n.t("reports.investment_performance.sells_count", count: 2))}/, response.body)
  end

  test "the breakdown account filter leaves out trades of other accounts" do
    create_trade(securities(:aapl), account: accounts(:investment), qty: 1, date: Date.current, price: 100)

    get reports_path(breakdown_period_params.merge(filter_account_id: accounts(:depository).id))
    assert_response :ok
    assert_select "div[data-category='category-other_investments']", count: 0

    get reports_path(breakdown_period_params.merge(filter_account_id: accounts(:investment).id))
    assert_response :ok
    assert_select "div[data-category='category-other_investments']"
  end

  test "a breakdown category filter lists the category's transactions and leaves trades out" do
    category = @family.categories.create!(name: "Filtered", classification: "expense", color: "#123456")
    create_transaction(account: accounts(:depository), name: "Filtered spend", amount: 42, category: category)
    create_trade(securities(:aapl), account: accounts(:investment), qty: 1, date: Date.current, price: 100)

    get reports_path(breakdown_period_params.merge(filter_category_id: category.id))

    assert_response :ok
    assert_select "div[data-category='category-#{category.id}']"
    assert_select "div[data-category='category-other_investments']", count: 0
  end

  test "a breakdown tag filter leaves trades out" do
    tag = tags(:one)
    create_transaction(account: accounts(:depository), name: "Tagged spend", amount: 42, tags: [ tag ])
    create_trade(securities(:aapl), account: accounts(:investment), qty: 1, date: Date.current, price: 100)

    get reports_path(breakdown_period_params.merge(filter_tag_id: tag.id))

    assert_response :ok
    assert_select "div[data-category='category-other_investments']", count: 0
  end

  test "breakdown amount and date filters apply to trades" do
    # The fixture trade (2,140, a day ago) would pass the minimum and the start date
    entries(:trade).destroy!
    create_trade(securities(:aapl), account: accounts(:investment), qty: 1, date: 10.days.ago.to_date, price: 100)

    get reports_path(breakdown_period_params)
    assert_select "div[data-category='category-other_investments']"

    get reports_path(breakdown_period_params.merge(filter_amount_min: 500))
    assert_select "div[data-category='category-other_investments']", count: 0

    get reports_path(breakdown_period_params.merge(filter_amount_max: 50))
    assert_select "div[data-category='category-other_investments']", count: 0

    get reports_path(breakdown_period_params.merge(filter_date_start: 2.days.ago.to_date))
    assert_select "div[data-category='category-other_investments']", count: 0

    get reports_path(breakdown_period_params.merge(filter_date_end: 20.days.ago.to_date))
    assert_select "div[data-category='category-other_investments']", count: 0
  end

  test "breakdown category rows link to their transactions for the report period" do
    category = @family.categories.create!(name: "Linked", classification: "expense", color: "#123456")
    create_transaction(account: accounts(:depository), name: "Linked spend", amount: 42, category: category)
    create_transaction(account: accounts(:depository), name: "Loose spend", amount: 17)
    create_trade(securities(:aapl), account: accounts(:investment), qty: 1, date: Date.current, price: 100)
    start_date = 30.days.ago.to_date
    end_date = Date.current

    get reports_path(breakdown_period_params)
    assert_response :ok

    assert_select "div[data-category='category-#{category.id}'] a[href=?]",
      transactions_path(q: { categories: [ "Linked" ], start_date: start_date, end_date: end_date })
    assert_select "div[data-category='category-uncategorized'] a[href=?]",
      transactions_path(q: { categories: [ Category::UNCATEGORIZED_FILTER_VALUE ], start_date: start_date, end_date: end_date })
    # /transactions does not list trades, so the trade-only row has no link
    assert_select "div[data-category='category-other_investments'] a", count: 0
  end

  test "the synthetic Other subcategory row has no link" do
    parent = @family.categories.create!(name: "Housing", classification: "expense", color: "#FF5733", lucide_icon: "home")
    rent = @family.categories.create!(name: "Rent", classification: "expense", parent: parent, lucide_icon: "home")
    create_transaction(account: accounts(:depository), name: "Home repair", amount: 200, category: parent)
    create_transaction(account: accounts(:depository), name: "Monthly rent", amount: 1500, category: rent)

    get reports_path(breakdown_period_params)
    assert_response :ok

    assert_select "div[data-category='category-#{parent.id}_other']"
    assert_select "div[data-category='category-#{parent.id}_other'] a", count: 0
    assert_select "div[data-category='category-#{rent.id}'] a"
  end

  test "reports render the spending vs normal section with links to the changed categories" do
    period_start = 2.months.ago.to_date.beginning_of_month
    period_end = period_start.end_of_month
    misc = @family.categories.create!(name: "Vs normal misc", classification: "expense", color: "#654321")
    dining = @family.categories.create!(name: "Vs normal dining", classification: "expense", color: "#123456")
    # Earlier history, so the period has a normal to compare with
    create_transaction(account: accounts(:depository), name: "Old spend", amount: 10, category: misc, date: period_start - 200.days)
    create_transaction(account: accounts(:depository), name: "Dinner", amount: 1_000, category: dining, date: period_start + 3.days)

    get reports_path(period_type: :custom, start_date: period_start, end_date: period_end)

    assert_response :ok
    assert_select "section[data-section-key='spending_vs_normal']"
    assert_select "[data-testid=spending-vs-normal] [data-controller='reports-treemap'][data-reports-treemap-color-mode-value='normal']"
    assert_select "[data-testid=spending-changes] a[href=?]",
      transactions_path(q: { categories: [ "Vs normal dining" ], start_date: period_start, end_date: period_end })
  end

  # A helper, not private: other streams append tests below it
  def breakdown_period_params
    { period_type: :custom, start_date: 30.days.ago.to_date, end_date: Date.current }
  end

  # -- Period arrows (period_offset) -----------------------------------------

  test "period offset steps back calendar periods of every type" do
    travel_to Date.new(2026, 3, 20) do
      @family.update!(use_fiscal_months: false)

      assert_report_period [ Date.new(2026, 3, 1), Date.new(2026, 3, 20) ], period_type: :monthly
      assert_report_period [ Date.new(2026, 2, 1), Date.new(2026, 2, 28) ], period_type: :monthly, period_offset: -1
      assert_report_period [ Date.new(2025, 12, 1), Date.new(2025, 12, 31) ], period_type: :monthly, period_offset: -3
      assert_report_period [ Date.new(2025, 10, 1), Date.new(2025, 12, 31) ], period_type: :quarterly, period_offset: -1
      assert_report_period [ Date.new(2025, 7, 1), Date.new(2025, 12, 31) ], period_type: :last_6_months, period_offset: -1
      assert_report_period [ Date.new(2025, 1, 1), Date.new(2025, 12, 31) ], period_type: :ytd, period_offset: -1
      assert_report_period [ Date.new(2024, 1, 1), Date.new(2024, 12, 31) ], period_type: :ytd, period_offset: -2
    end
  end

  test "period offset steps back fiscal periods of every type" do
    travel_to Date.new(2026, 3, 20) do
      @family.update!(use_fiscal_months: true, fiscal_month_start_day: 10)

      assert_report_period [ Date.new(2026, 3, 10), Date.new(2026, 3, 20) ], period_type: :monthly
      assert_report_period [ Date.new(2026, 2, 10), Date.new(2026, 3, 9) ], period_type: :monthly, period_offset: -1
      assert_report_period [ Date.new(2025, 10, 10), Date.new(2026, 1, 9) ], period_type: :quarterly, period_offset: -1
      assert_report_period [ Date.new(2025, 7, 10), Date.new(2026, 1, 9) ], period_type: :last_6_months, period_offset: -1
      assert_report_period [ Date.new(2025, 1, 10), Date.new(2026, 1, 9) ], period_type: :ytd, period_offset: -1

      # Calendar mode on a fiscal family steps calendar periods
      assert_report_period [ Date.new(2026, 2, 1), Date.new(2026, 2, 28) ], period_type: :monthly, fiscal_mode: "false", period_offset: -1
    end
  end

  test "fiscal steps go back to the start day after a month that clamps it" do
    travel_to Date.new(2026, 3, 31) do
      @family.update!(use_fiscal_months: true, fiscal_month_start_day: 31)

      assert_report_period [ Date.new(2026, 2, 28), Date.new(2026, 3, 30) ], period_type: :monthly, period_offset: -1
      assert_report_period [ Date.new(2026, 1, 31), Date.new(2026, 2, 27) ], period_type: :monthly, period_offset: -2
    end
  end

  test "period_mode=last from old links means one period back" do
    travel_to Date.new(2026, 3, 20) do
      @family.update!(use_fiscal_months: false)

      assert_report_period [ Date.new(2026, 2, 1), Date.new(2026, 2, 28) ], period_type: :monthly, period_mode: "last"
      assert_report_period [ Date.new(2025, 10, 1), Date.new(2025, 12, 31) ], period_type: :quarterly, period_mode: "last"
      # An explicit offset wins over the old mode
      assert_report_period [ Date.new(2026, 1, 1), Date.new(2026, 1, 31) ], period_type: :monthly, period_mode: "last", period_offset: -2
    end
  end

  test "a future or invalid period offset shows the current period" do
    travel_to Date.new(2026, 3, 20) do
      @family.update!(use_fiscal_months: false)

      assert_report_period [ Date.new(2026, 3, 1), Date.new(2026, 3, 20) ], period_type: :monthly, period_offset: 2
      assert_report_period [ Date.new(2026, 3, 1), Date.new(2026, 3, 20) ], period_type: :monthly, period_offset: "abc"
      assert_report_period [ Date.new(2026, 3, 1), Date.new(2026, 3, 20) ], period_type: :unknown
    end
  end

  test "a custom range steps by its own length" do
    assert_report_period [ Date.new(2026, 2, 19), Date.new(2026, 2, 28) ],
      period_type: :custom, start_date: "2026-03-01", end_date: "2026-03-10", period_offset: -1
    assert_report_period [ Date.new(2026, 2, 9), Date.new(2026, 2, 18) ],
      period_type: :custom, start_date: "2026-03-01", end_date: "2026-03-10", period_offset: -2

    # The arrows keep the chosen range as their anchor
    assert_select "a[data-hotkey='ArrowLeft'][href=?]",
      reports_path(period_type: :custom, start_date: "2026-03-01", end_date: "2026-03-10", period_offset: -3)
    assert_select "a[data-hotkey='ArrowRight'][href=?]",
      reports_path(period_type: :custom, start_date: "2026-03-01", end_date: "2026-03-10", period_offset: -1)
  end

  # The next arrow used to be a disabled <button> that looked active and
  # then refused the click; Current used to vanish and shift the row.
  test "on the current period the next arrow is greyed out and Current keeps an invisible slot" do
    get reports_path(period_type: :monthly)
    assert_response :ok

    assert_select "span[role='link'][aria-disabled='true'].text-subdued[aria-label=?]", I18n.t("reports.index.period_nav.next")
    assert_select "button[aria-label=?]", I18n.t("reports.index.period_nav.next"), count: 0
    assert_select "a[data-hotkey='ArrowRight']", count: 0
    assert_select "a[data-hotkey='ArrowLeft'][href=?]", reports_path(period_type: :monthly, fiscal_mode: "false", period_offset: -1)
    assert_select "[data-testid='report-period-current'].invisible[aria-hidden='true'][tabindex='-1']", text: I18n.t("reports.index.period_nav.current")
    # The Current/Last toggle is gone
    assert_select "a[href*='period_mode']", count: 0
  end

  test "every period type and mode greys out the next arrow on its current period" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 10)

    %i[monthly quarterly last_6_months ytd].product(%w[true false]).each do |period_type, fiscal_mode|
      get reports_path(period_type: period_type, fiscal_mode: fiscal_mode)
      assert_select "span[aria-disabled='true'][data-period-arrow='next']", 1, "#{period_type} fiscal=#{fiscal_mode}"
      assert_select "a[data-period-arrow='previous']", 1, "#{period_type} fiscal=#{fiscal_mode}"

      get reports_path(period_type: period_type, fiscal_mode: fiscal_mode, period_offset: -1)
      assert_select "a[data-period-arrow='next']", 1, "#{period_type} fiscal=#{fiscal_mode} offset -1"
      assert_select "[data-testid='report-period-current']:not(.invisible)", 1
    end

    get reports_path(period_type: :custom, start_date: "2026-03-01", end_date: "2026-03-10")
    assert_select "span[aria-disabled='true'][data-period-arrow='next']", 1
  end

  # Every label the period type can show sits invisibly in the label's grid
  # cell, so the cell is as wide as the widest one and the row never moves.
  test "the period label reserves the width of its widest label" do
    travel_to Date.new(2026, 3, 20) do
      @family.update!(use_fiscal_months: false)

      get reports_path(period_type: :monthly)
      assert_select "[data-testid='report-period-nav'] .inline-grid [aria-hidden='true'].invisible", 12
      assert_select "[data-testid='report-period-nav'] .inline-grid [aria-hidden='true']", text: "September 2026"

      get reports_path(period_type: :quarterly)
      assert_select "[data-testid='report-period-nav'] .inline-grid [aria-hidden='true']", 4

      get reports_path(period_type: :ytd, period_offset: -1)
      assert_select "[data-testid='report-period-label']", text: "2025"
      assert_select "[data-testid='report-period-nav'] .inline-grid [aria-hidden='true']", text: "2025 to date"

      get reports_path(period_type: :custom, start_date: "2026-03-01", end_date: "2026-03-10")
      assert_select "[data-testid='report-period-nav'] .inline-grid [aria-hidden='true']", text: "Sep 28, 2026 – Sep 28, 2026"
    end
  end

  test "a past period links forward and back to the current period" do
    travel_to Date.new(2026, 3, 20) do
      @family.update!(use_fiscal_months: false)
      get reports_path(period_type: :quarterly, period_offset: -2)
      assert_response :ok

      assert_select "a[data-hotkey='ArrowLeft'][href=?]", reports_path(period_type: :quarterly, fiscal_mode: "false", period_offset: -3)
      assert_select "a[data-hotkey='ArrowRight'][href=?]", reports_path(period_type: :quarterly, fiscal_mode: "false", period_offset: -1)
      assert_select "[data-testid='report-period-nav'] a[href=?]", reports_path(period_type: :quarterly, fiscal_mode: "false"),
        text: I18n.t("reports.index.period_nav.current")
      assert_select "[data-testid='report-period-label']", text: "Q3 2025"
    end
  end

  test "the period label names the period" do
    travel_to Date.new(2026, 3, 20) do
      @family.update!(use_fiscal_months: false)

      get reports_path(period_type: :monthly, period_offset: -1)
      assert_select "[data-testid='report-period-label']", text: "February 2026"
      get reports_path(period_type: :last_6_months, period_offset: -1)
      assert_select "[data-testid='report-period-label']", text: "H2 2025"
      get reports_path(period_type: :ytd)
      assert_select "[data-testid='report-period-label']", text: "2026 to date"
      get reports_path(period_type: :ytd, period_offset: -1)
      assert_select "[data-testid='report-period-label']", text: "2025"
    end
  end

  test "period arrows carry their keyboard shortcuts" do
    get reports_path(period_type: :monthly, period_offset: -2)
    assert_response :ok

    assert_select "a[aria-keyshortcuts='ArrowLeft'][data-hotkey='ArrowLeft']"
    assert_select "a[aria-keyshortcuts='ArrowRight'][data-hotkey='ArrowRight']"
    assert_select "[role='tooltip']", text: "Previous period (←)"
    assert_select "[role='tooltip']", text: "Next period (→)"
  end

  test "the sort link keeps the period offset" do
    travel_to Date.new(2026, 3, 20) do
      @family.update!(use_fiscal_months: false)
      create_transaction(account: accounts(:depository), date: Date.new(2026, 1, 12), amount: 25, category: categories(:food_and_drink))

      get reports_path(period_type: :monthly, period_offset: -2)
      assert_response :ok

      assert_select "a[href*='sort_by=amount'][href*='period_offset=-2']"
    end
  end

  test "the net worth section shows the monthly chart with the account groups" do
    travel_to Date.new(2026, 9, 20) do
      create_balance(account: accounts(:depository), date: Date.new(2026, 7, 1), balance: 4_000)
      create_balance(account: accounts(:credit_card), date: Date.new(2026, 7, 1), balance: 900)

      get reports_path(period_type: :custom, start_date: "2026-03-20", end_date: "2026-09-20")
      assert_response :ok

      assert_select "section[data-section-key='net_worth'] [data-testid='net-worth-over-time']" do
        assert_select "p", text: I18n.t("reports.net_worth.chart.title")
        assert_select "#reportsNetWorthChart[data-controller='net-worth-chart']" \
          "[data-net-worth-chart-assets-label-value='#{I18n.t("reports.net_worth.total_assets")}']" \
          "[data-net-worth-chart-liabilities-label-value='#{I18n.t("reports.net_worth.total_liabilities")}']"
      end

      data = JSON.parse(css_select("#reportsNetWorthChart").first["data-net-worth-chart-data-value"])
      assert_equal "1 month", data["interval"]
      assert_equal 7, data["values"].size
      assert_equal "2026-09-20", data["values"].last["date"]

      last_groups = data["values"].last["groups"].to_h { |g| [ g["name"], g["value"]["amount"].to_d ] }
      assert_equal 4_000, last_groups.fetch(I18n.t("accounts.types.depository"))
      assert_equal 900, last_groups.fetch(I18n.t("accounts.types.credit_card"))
    end
  end

  # -- w3-reports exclude-from-reports ---------------------------------------

  test "the export and the breakdown leave out an account excluded from reports" do
    excluded = @family.accounts.create!(name: "Hidden savings", currency: @family.currency, balance: 0, accountable: Depository.new, exclude_from_reports: true)
    hidden_category = @family.categories.create!(name: "Only in the excluded account", classification: "expense")
    shown_category = @family.categories.create!(name: "In an included account", classification: "expense")
    create_transaction(account: excluded, amount: 75, category: hidden_category, currency: @family.currency)
    create_transaction(account: accounts(:depository), amount: 25, category: shown_category, currency: @family.currency)

    get export_transactions_reports_path(format: :csv, period_type: :monthly)
    assert_response :ok
    assert_includes @response.body, shown_category.name
    assert_not_includes @response.body, hidden_category.name

    get reports_path(period_type: :monthly)
    assert_response :ok
    breakdown_names = controller.instance_variable_get(:@transactions).flat_map { |group| [ group[:category_name], *Array(group[:subcategories]).map { |sub| sub[:category_name] } ] }
    assert_includes breakdown_names, shown_category.name
    assert_not_includes breakdown_names, hidden_category.name
  end

  private
    def assert_report_period(expected, **query)
      get reports_path(query)
      assert_response :ok
      assert_equal expected, [ controller.instance_variable_get(:@start_date), controller.instance_variable_get(:@end_date) ],
        "period for #{query.inspect}"
    end
end
