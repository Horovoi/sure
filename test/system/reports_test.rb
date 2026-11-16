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

  test "switch the expenses treemap to vs normal, keep it after a reload and open a changed category" do
    period_start = 2.months.ago.to_date.beginning_of_month
    period_end = period_start.end_of_month
    dining = @family.categories.create!(name: "Vs normal dining", classification: "expense", color: "#123456")
    create_transaction(account: @account, currency: @family.currency, amount: 10, name: "Old receipt", date: period_start - 200.days)
    create_transaction(account: @account, currency: @family.currency, category: dining, amount: 1_000, name: "Big dinner", date: period_start + 3.days)

    visit reports_path(period_type: :custom, start_date: period_start, end_date: period_end)

    assert_no_selector "[data-section-key='spending_vs_normal']"
    # Category colours first, like the income treemap
    assert_selector "[data-testid=breakdown-expense][data-color-mode='category']"
    within "[data-testid=breakdown-expense]" do
      assert_selector "[data-testid=spending-summary]"
      assert_selector "svg g[data-category-name='Vs normal dining']"
      assert_selector "[data-testid=spending-legend]", visible: :hidden

      click_button I18n.t("reports.spending_vs_normal.color_mode.normal")
      assert_selector "[data-testid=spending-legend]", visible: true
      assert_selector "button[aria-pressed='true']", text: I18n.t("reports.spending_vs_normal.color_mode.normal")
    end
    assert_selector "[data-testid=breakdown-expense][data-color-mode='normal']"

    # The choice is saved for the user: a fresh visit opens in Vs normal
    assert_selector "[data-testid=breakdown-expense][data-saved-color-mode='normal']"
    visit reports_path(period_type: :custom, start_date: period_start, end_date: period_end)
    assert_selector "[data-testid=breakdown-expense][data-color-mode='normal']"

    within "[data-testid=breakdown-expense]" do
      assert_selector "[data-testid=spending-legend]", visible: true

      click_button I18n.t("reports.spending_vs_normal.color_mode.category")
      assert_selector "[data-testid=spending-legend]", visible: :hidden

      within "[data-testid=spending-changes]" do
        click_link "Vs normal dining"
      end
    end

    assert_current_path(/\/transactions/)
    assert_text "Big dinner"
    assert_no_text "Corner shop"
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
  # Current link that comes and goes pushed the Calendar/Fiscal switch around.
  test "the period bar keeps its place while stepping through months" do
    @family.update!(use_fiscal_months: true, fiscal_month_start_day: 17)
    visit reports_path(period_type: :monthly, fiscal_mode: "true")

    toggle_x = -> { find("[data-testid='report-period-nav'] + div a", text: I18n.t("reports.index.toggles.calendar")).native.rect.x }
    next_x = -> { find("[data-period-arrow='next']").native.rect.x }
    start_toggle_x = toggle_x.call
    start_next_x = next_x.call

    labels = [ find("[data-testid='report-period-label']").text ]
    4.times do |step|
      find("a[aria-keyshortcuts='ArrowLeft']").click
      assert_current_path(/period_offset=-#{step + 1}/)
      labels << find("[data-testid='report-period-label']").text

      assert_equal start_toggle_x, toggle_x.call, "the Calendar/Fiscal switch moved on #{labels.last}"
      assert_equal start_next_x, next_x.call, "the next arrow moved on #{labels.last}"
    end
    assert_equal 5, labels.uniq.size
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

    click_link I18n.t("reports.transactions_breakdown.export.google_sheets")
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
    def visit_breakdown
      visit reports_path(period_type: :custom, start_date: 30.days.ago.to_date, end_date: Date.current)

      # The category table sits in a closed <details> under the expense treemap
      within "[data-section-key='transactions_breakdown']" do
        all("summary", text: /View category details/).each(&:click)
      end
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
