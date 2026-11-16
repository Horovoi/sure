require "application_system_test_case"

class ReportsTest < ApplicationSystemTestCase
  include EntriesTestHelper
  include BalanceTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = @family.accounts.create!(name: "Reports checking", currency: @family.currency, balance: 0, accountable: Depository.new)
    @category = @family.categories.create!(name: "Reports Groceries", classification: "expense", color: "#123456")
    create_transaction(account: @account, currency: @family.currency, category: @category, amount: 42, name: "Corner shop", date: Date.current)
    create_transaction(account: @account, currency: @family.currency, amount: 17, name: "Loose receipt", date: Date.current)
    # History years back, so the back arrow has earlier periods to step into
    create_transaction(account: @account, currency: @family.currency, amount: 5, name: "Old history", date: 3.years.ago.to_date)
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

  test "an expense row shows its change against normal, opens its details and then its transactions" do
    period_start = 2.months.ago.to_date.beginning_of_month
    period_end = period_start.end_of_month
    dining = @family.categories.create!(name: "Vs normal dining", classification: "expense", color: "#123456")
    create_transaction(account: @account, currency: @family.currency, amount: 10, name: "Old receipt", date: period_start - 200.days)
    create_transaction(account: @account, currency: @family.currency, category: dining, amount: 1_000, name: "Big dinner", date: period_start + 3.days)

    visit reports_path(period_type: :custom, start_date: period_start, end_date: period_end)

    assert_no_selector "[data-section-key='spending_vs_normal']"
    within "[data-testid=breakdown-expense]" do
      assert_selector "[data-testid=spending-summary]", text: "more than normal"
      assert_selector "[data-testid=spending-legend]", text: "based on"

      within "[data-category='category-#{dining.id}']" do
        assert_selector "[data-testid=breakdown-delta]", text: "+"
        find("button[aria-label='#{I18n.t("reports.transactions_breakdown.column.details", category: "Vs normal dining")}']").click
      end
      assert_selector "[data-testid=breakdown-details]", text: "1 transaction", visible: true
      find("[data-category='category-#{dining.id}'] button[aria-expanded='true']").click
      assert_no_selector "[data-testid=breakdown-details]", visible: true

      within "[data-category='category-#{dining.id}']" do
        click_link "Vs normal dining"
      end
    end

    assert_current_path(/\/transactions/)
    assert_text "Big dinner"
    assert_no_text "Corner shop"
  end

  test "the rest of a long list opens and closes from one row" do
    10.times do |index|
      category = @family.categories.create!(name: "Many #{index}", classification: "expense", color: "#123456")
      create_transaction(account: @account, currency: @family.currency, category: category, amount: 100 + index, name: "Spend #{index}", date: Date.current)
    end

    visit_breakdown

    within "[data-testid=breakdown-expense]" do
      # The fixtures add expense rows of their own
      rows = all("#breakdown-expense-list > li", visible: :all).size
      assert_operator rows, :>=, 10 + ReportsHelper::BREAKDOWN_MIN_TAIL
      assert_selector "#breakdown-expense-list > li", count: ReportsHelper::BREAKDOWN_TOP_ROWS
      more = find("[data-testid=breakdown-expense-more]")
      assert_text "#{rows - ReportsHelper::BREAKDOWN_TOP_ROWS} more categories"

      more.click
      assert_selector "#breakdown-expense-list > li", count: rows
      assert_selector "[data-testid=breakdown-expense-more][aria-expanded='true']", text: I18n.t("reports.transactions_breakdown.column.fewer")

      more.click
      assert_selector "#breakdown-expense-list > li", count: ReportsHelper::BREAKDOWN_TOP_ROWS
    end
  end

  test "the export menu in the section header holds both exports" do
    visit_breakdown

    within "section[data-section-key='transactions_breakdown'] [data-testid=breakdown-export]" do
      click_button I18n.t("reports.transactions_breakdown.export.label")
      assert_selector "a[role=menuitem]", text: I18n.t("reports.transactions_breakdown.export.csv")
      click_link I18n.t("reports.transactions_breakdown.export.google_sheets")
    end
    assert_selector "dialog[open]"
  end

  # --- w2-netw ---

  test "the arrows step through periods and Current goes back" do
    visit reports_path(period_type: :monthly)
    current_label = find("[data-testid='report-period-label']").text
    assert_selector "span[aria-disabled='true'][aria-label='#{I18n.t("reports.index.period_nav.next")}']"

    find("a[aria-keyshortcuts='ArrowLeft']").click
    assert_current_path(/period_offset=-1/)
    assert_no_selector "[data-testid='report-period-label']", text: current_label, exact_text: true

    find("a[aria-keyshortcuts='ArrowRight']").click
    assert_no_current_path(/period_offset/)
    assert_selector "[data-testid='report-period-label']", text: current_label, exact_text: true

    find("a[aria-keyshortcuts='ArrowLeft']").click
    find("a[aria-keyshortcuts='ArrowLeft']").click
    assert_current_path(/period_offset=-2/)
    within("[data-testid='report-period-nav']") { click_link I18n.t("reports.index.period_nav.current") }
    assert_no_current_path(/period_offset/)
    assert_selector "[data-testid='report-period-label']", text: current_label, exact_text: true
  end

  # The label used to be as wide as its text, so September, October and the
  # Current link that comes and goes pushed the controls after it around.
  # Back to current now appears at the end of the line under the label.
  test "the period header keeps its place while stepping through months" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 17)
    visit reports_path(period_type: :monthly, fiscal_mode: "true")

    start = header_positions
    labels = [ find("[data-testid='report-period-label']").text ]
    4.times do |step|
      find("a[aria-keyshortcuts='ArrowLeft']").click
      assert_current_path(/period_offset=-#{step + 1}/)
      labels << find("[data-testid='report-period-label']").text
      assert_selector "[data-testid='report-period-current']"

      assert_equal start, header_positions, "the header moved on #{labels.last}"
    end
    assert_equal 5, labels.uniq.size
  end

  # The label slot used to be only as wide as the widest label of the period
  # type, so Month, Quarter, 6 months and Year each put the controls elsewhere.
  test "the period header keeps its place across period types" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 17)
    tabs = { "month" => "monthly", "quarter" => "quarterly", "six_months" => "last_6_months", "year" => "ytd" }

    [ [ 1400, 1400 ], [ 390, 900 ] ].each do |width, height|
      with_window_size(width, height) do
        visit reports_path(period_type: :monthly, fiscal_mode: "true")

        positions = tabs.map do |key, period_type|
          within("[data-testid='report-period-types']") { click_link I18n.t("reports.index.periods.#{key}") }
          assert_current_path(/period_type=#{period_type}/)
          assert_equal width, evaluate_script("window.innerWidth")
          assert_not evaluate_script("document.documentElement.scrollWidth > window.innerWidth"), "the page scrolls sideways at #{width} wide"
          header_positions
        end

        assert_equal 1, positions.uniq.size, "the header moved between period types at #{width} wide: #{positions}"
      end
    end
  end

  test "the options menu switches between calendar and fiscal months" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 17)
    visit reports_path(period_type: :monthly)
    assert_selector "[data-testid='report-period-range']", text: I18n.t("reports.index.period_nav.fiscal_range.monthly", range: "").strip

    within("[data-testid='report-options']") do
      find("button[aria-label='#{I18n.t("reports.index.more_options")}']").click
      assert_selector "[role='menuitemradio'][aria-checked='true']", text: I18n.t("reports.index.toggles.fiscal")
      assert_selector "[role='menuitem']", text: I18n.t("reports.index.print_report")
      click_link I18n.t("reports.index.toggles.calendar")
    end

    assert_current_path(/fiscal_mode=false/)
    assert_no_selector "[data-testid='report-period-range']", text: "fiscal"
    assert_selector "[data-testid='report-period-label']", text: I18n.l(Date.current, format: "%B %Y")
  end

  # With the accounts and assistant panels open (the default), the main
  # column is narrow on a wide screen: income and expenses stack there and
  # sit side by side once the panels close. Either way every bar keeps room
  # and no name is cut off.
  test "income and expenses stack in a narrow main column and sit side by side in a wide one" do
    create_spending_history
    create_transaction(account: @account, currency: @family.currency, amount: -5_000, name: "Pay", date: @period_start + 2.days)

    visit reports_path(period_type: :custom, start_date: @period_start, end_date: @period_end)
    assert_operator main_width, :<, 700, "both side panels are open"
    income = find("[data-testid=breakdown-income]").native.rect
    expense = find("[data-testid=breakdown-expense]").native.rect
    assert_operator expense.y, :>=, income.y + income.height, "expenses stack under income"
    assert_list_rows_fit

    @user.update!(show_sidebar: false, show_ai_sidebar: false)
    visit reports_path(period_type: :custom, start_date: @period_start, end_date: @period_end)
    assert_operator main_width, :>, 900
    income = find("[data-testid=breakdown-income]").native.rect
    expense = find("[data-testid=breakdown-expense]").native.rect
    assert_in_delta income.y, expense.y, 1, "the two lists start on one line"
    assert_operator expense.x, :>, income.x + income.width, "expenses sit beside income"
    assert_list_rows_fit
  end

  # The four summary cards stayed in four columns inside the narrow main
  # column and cut off their amounts.
  test "the summary cards fit the main column with the side panels open" do
    visit reports_path(period_type: :monthly)
    assert_operator main_width, :<, 700, "both side panels are open"

    within "[data-testid=report-summary]" do
      cards = all(".bg-container", minimum: 4)
      assert_equal 2, cards.map { |card| card.native.rect.x }.uniq.size, "two columns"
      cards.each do |card|
        overflow = evaluate_script(<<~JS, card)
          (function(card) { return Array.from(card.querySelectorAll("*")).some((el) => el.scrollWidth > el.clientWidth + 1 || el.getBoundingClientRect().right > card.getBoundingClientRect().right + 1) })(arguments[0])
        JS
        assert_not overflow, "#{card.text.squish} overflows its card"
      end
    end
  end

  test "the left and right arrow keys change the period" do
    visit reports_path(period_type: :quarterly)
    wait_for_hotkeys

    page.send_keys(:arrow_left)
    assert_current_path(/period_offset=-1/)
    wait_for_hotkeys

    page.send_keys(:arrow_left)
    assert_current_path(/period_offset=-2/)
    wait_for_hotkeys

    page.send_keys(:arrow_right)
    assert_current_path(/period_offset=-1/)
  end

  test "the arrow keys leave section moves and dialogs alone" do
    visit reports_path(period_type: :monthly)
    wait_for_hotkeys
    record_hotkey_clicks

    find("section[data-section-key]", match: :first).send_keys(:enter)
    page.send_keys(:arrow_left)
    assert_empty clicked_hotkeys
    page.send_keys(:escape)

    within("[data-testid=breakdown-export]") do
      click_button I18n.t("reports.transactions_breakdown.export.label")
      click_link I18n.t("reports.transactions_breakdown.export.google_sheets")
    end
    assert_selector "dialog[open]"
    page.send_keys(:arrow_left)
    assert_empty clicked_hotkeys

    page.send_keys(:escape)
    assert_no_selector "dialog[open]"
    page.send_keys(:arrow_left)
    assert_equal %w[ArrowLeft], clicked_hotkeys
  end

  test "a held arrow key steps one period" do
    visit reports_path(period_type: :monthly)
    wait_for_hotkeys
    record_hotkey_clicks

    page.execute_script(<<~JS)
      for (const repeat of [false, true, true]) {
        document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", repeat, bubbles: true }));
      }
    JS

    assert_equal %w[ArrowLeft], clicked_hotkeys
  end

  test "the net worth chart lists each account group in its tooltip" do
    create_balance(account: accounts(:depository), date: 4.months.ago.to_date, balance: 4_000)
    create_balance(account: accounts(:credit_card), date: 4.months.ago.to_date, balance: 900)

    visit reports_path(period_type: :custom, start_date: 6.months.ago.to_date.iso8601, end_date: Date.current.iso8601)

    within "[data-testid='net-worth-over-time']" do
      assert_text I18n.t("reports.net_worth.chart.title")
      assert_selector "#reportsNetWorthChart svg"
    end

    # The middle of the chart is three months back, after the balances above
    find("#reportsNetWorthChart svg").hover

    within "#reportsNetWorthChart [data-testid='net-worth-breakdown']" do
      assert_text(/#{Regexp.escape(I18n.t("reports.net_worth.total_assets"))}/i)
      assert_text(/#{Regexp.escape(I18n.t("reports.net_worth.total_liabilities"))}/i)
      assert_text I18n.t("accounts.types.depository")
      assert_text I18n.t("accounts.types.credit_card")
    end
  end

  private
    # A desktop Chrome window does not get narrower than about 500px; the
    # emulated screen does
    def with_window_size(width, height)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
      yield
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end

    # Where the next arrow, the period-length control and the first summary
    # card are: none of them may move when the period changes.
    def header_positions
      {
        next: find("[data-period-arrow='next']").native.rect.x,
        types: find("[data-testid='report-period-types']").native.rect.then { |rect| [ rect.x, rect.y ] },
        summary: find("[data-testid='report-summary']").native.rect.y
      }
    end

    def main_width
      evaluate_script("document.querySelector('main').getBoundingClientRect().width")
    end

    # 14 expense categories spent in a past month, with a year of history
    # before it, so "What changed" lists a long column of moves
    def create_spending_history
      @period_start = 2.months.ago.to_date.beginning_of_month
      @period_end = @period_start.end_of_month

      14.times do |index|
        category = @family.categories.create!(name: "Spending category #{index + 1}", classification: "expense", color: "#123456")
        1.upto(6) do |months_back|
          create_transaction(account: @account, currency: @family.currency, category: category,
            amount: 100 + (index * 10), name: "Usual #{index}", date: @period_start - months_back.months + 5.days)
        end
        current = index.even? ? 400 + (index * 50) : 20 + index
        create_transaction(account: @account, currency: @family.currency, category: category,
          amount: current, name: "This month #{index}", date: @period_start + 5.days)
      end
    end

    # Every visible row of the expense list keeps a usable bar and its whole name
    def assert_list_rows_fit
      rows = all("[data-testid=breakdown-expense] #breakdown-expense-list > li > div[data-category]", minimum: ReportsHelper::BREAKDOWN_TOP_ROWS)
      rows.each do |row|
        bar = row.find("div[aria-hidden='true']", visible: :all)
        assert_operator bar.native.rect.width, :>=, 120, "#{row.text.squish} has room for its bar"
        name = row.first(".truncate")
        assert_not evaluate_script("arguments[0].scrollWidth > arguments[0].clientWidth", name), "#{name.text} is cut off"
      end
    end

    def visit_breakdown
      visit reports_path(period_type: :custom, start_date: 30.days.ago.to_date, end_date: Date.current)
      assert_selector "[data-section-key='transactions_breakdown'] [data-controller='breakdown-list']"
    end

    # The tooltip only shows once the page's controllers are connected, so
    # keys pressed after this reach an installed hotkey.
    def wait_for_hotkeys
      find("a[aria-keyshortcuts='ArrowLeft']").hover
      assert_selector "[role='tooltip']", text: "Previous period (←)"
      # Move the pointer away so the tooltip does not cover the page. The page's own
      # heading: the chat sidebar has an h1 of its own.
      find("main h1").hover
    end

    # Records the links the hotkeys click instead of following them. A hotkey
    # clicks synchronously, so the list is complete when the key returns.
    def record_hotkey_clicks
      page.execute_script(<<~JS)
        window.clickedHotkeys = [];
        document.addEventListener("click", (event) => {
          const link = event.target.closest("a[data-hotkey]");
          if (!link) return;
          window.clickedHotkeys.push(link.dataset.hotkey);
          event.preventDefault();
        }, true);
      JS
    end

    def clicked_hotkeys
      page.evaluate_script("window.clickedHotkeys")
    end
end
