require "test_helper"

# Privacy mode blurs every element marked .privacy-sensitive. This test renders
# the main pages (and the turbo frames they load lazily) and fails on any
# currency-formatted amount that is not inside such an element, so a new view
# cannot show money that privacy mode leaves readable.
#
# It checks visible text and the attributes a browser shows (title, alt,
# placeholder). aria-label is left out on purpose: the blur is visual only and
# screen readers still read amounts (see privacy-mode.css). Chart data in data-*-value attributes is drawn by D3, which adds
# the class itself (see app/javascript/utils/chart_tooltip.js and the chart
# controllers), so it is out of reach here.
class PrivacyModeCoverageTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  include MonobankTestHelper

  # A currency symbol next to a digit: "$1,234.56", "-$12", "1 234,56 €", "₴500".
  MONEY = /\p{Sc}\s?[-−]?\d|\d\s?\p{Sc}/
  SHOWN_ATTRIBUTES = %w[title alt placeholder].freeze
  SKIPPED_TAGS = %w[script style noscript].freeze

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)

    food = categories(:food_and_drink)
    income = categories(:income)
    3.times do |i|
      create_transaction(account: @account, name: "Groceries #{i}", amount: 40 + i, category: food, date: Date.current - i.days)
      create_transaction(account: @account, name: "Groceries last month #{i}", amount: 30 + i, category: food, date: Date.current.prev_month - i.days)
    end
    create_transaction(account: @account, name: "Salary", amount: -2500, category: income, date: Date.current)

    # A split transaction, for the grouped list rows, the split box in the drawer and the editor
    @split = create_transaction(account: @account, name: "Supermarket", amount: 100, category: food, date: Date.current)
    @split.split!([ { name: "Food part", amount: 60, category_id: food.id }, { name: "Household part", amount: 40 } ])

    @budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    @budget.budget_categories.each { |bc| bc.update!(budgeted_spending: 300) }

    recurring_transactions(:netflix_subscription).update!(subscription_state: "subscription", billing_cycle: "yearly", expected_month: 12)
    @family.recurring_transactions.create!(name: "Gym", amount: 30, currency: "USD", expected_day_of_month: 3,
                                           next_expected_date: 3.days.from_now.to_date, last_occurrence_date: 1.month.ago.to_date,
                                           status: "active", subscription_state: "suggested", occurrence_count: 3)
    @family.recurring_transactions.create!(name: "Rent", amount: 900, currency: "USD", expected_day_of_month: 1,
                                           expected_amount_min: 850, expected_amount_max: 950, expected_amount_avg: 900,
                                           next_expected_date: 10.days.from_now.to_date, last_occurrence_date: 20.days.ago.to_date,
                                           status: "active", manual: true, occurrence_count: 3)

    setup_monobank_family
    create_monobank_product(account_id: "uah-card", balance: 4_200_000, credit_limit: 5_000_000)
    create_monobank_product(account_id: "jar-1", kind: "jar", title: "Holiday", balance: 150_000, goal: 2_000_000)

    # An import with a CSV, for the sample table and the rows to clean
    @import = imports(:transaction)
    @import.update!(raw_file_str: "date,amount,name\n01/01/2024,-12.50,Coffee\n", date_col_label: "date", amount_col_label: "amount", name_col_label: "name")
    TransactionImport.any_instance.stubs(:configured?).returns(true)

    @chat = chats(:one)
    @chat.messages.create!(type: "AssistantMessage", content: "You spent **$1,234.56** on food, about $41 a day.", ai_model: "gpt-4.1", status: "complete")
  end

  test "money on the main pages is privacy-sensitive" do
    @blurred = Hash.new(0)
    leaks = pages.flat_map { |label, path| leaks_on("#{label} (#{path})", path, page: label) }
    # Each page shows some blurred money, so a page that renders no amounts
    # (missing test data, a broken page) cannot pass the check unnoticed
    leaks += pages.keys.reject { |label| @blurred[label].positive? }.map { |label| [ label, "shows no blurred amount at all" ] }

    report = leaks.group_by(&:last).map do |leak, found_on|
      pages_found = found_on.map(&:first).uniq
      "#{leak}\n    on #{pages_found.first}#{" and #{pages_found.size - 1} more" if pages_found.size > 1}"
    end
    assert leaks.empty?, "Amounts privacy mode would leave readable (wrap them in .privacy-sensitive):\n#{report.join("\n")}"
  end

  private
    def pages
      transaction_entry = @account.entries.where(entryable_type: "Transaction").order(:date).last
      budget_category = @budget.budget_categories.first

      list = {
        "dashboard" => root_path,
        "accounts" => accounts_path,
        "transactions" => transactions_path,
        "transaction drawer" => transaction_path(transaction_entry),
        "reports" => reports_path,
        "reports print" => print_reports_path,
        "budget" => budget_path(@budget),
        "budget category" => budget_budget_category_path(@budget, budget_category),
        "goals" => goals_path,
        "subscriptions" => subscriptions_path,
        "subscription calendar" => calendar_subscriptions_path,
        "insights" => insights_path,
        "auto matches" => auto_matches_path,
        "categorize" => transactions_categorize_path,
        "merchant" => family_merchant_path(merchants(:netflix)),
        "transfer" => transfer_path(transfers(:one)),
        "holding" => holding_path(holdings(:one)),
        "trade" => trade_path(trades(:one).entry),
        "valuation" => valuation_path(valuations(:one).entry),
        "monobank setup" => setup_accounts_monobank_item_path(monobank_items(:one)),
        "other recurring" => subscriptions_path(kind: SubscriptionsController::OTHER_RECURRING_KIND),
        "subscription suggestions" => suggestions_subscriptions_path,
        "import configuration" => import_configuration_path(@import),
        "import clean" => import_clean_path(@import),
        "chat" => chat_path(@chat)
      }
      list["plan"] = plan_path if respond_to?(:plan_path)
      if respond_to?(:edit_transaction_split_path)
        list["split drawer"] = transaction_path(@split)
        list["split part drawer"] = transaction_path(@split.child_entries.first)
        list["split editor"] = edit_transaction_split_path(@split)
      end

      @family.accounts.each { |account| list["account #{account.name}"] = account_path(account) }
      @family.goals.each { |goal| list["goal #{goal.name}"] = goal_path(goal) }
      list
    end

    def leaks_on(label, path, page:, frame: nil, depth: 0)
      get path, headers: { "Turbo-Frame" => frame }.compact
      follow_redirect! while response.redirect?
      return [ [ label, "HTTP #{response.status}" ] ] unless response.successful?

      document = Nokogiri::HTML5(response.body)
      @blurred[page] += blurred_amounts(document)
      leaks = text_leaks(document) + attribute_leaks(document)
      leaks = leaks.map { |leak| [ label, leak ] }

      return leaks if depth > 0

      lazy_frames(document).each do |frame_id, frame_path|
        leaks.concat leaks_on("#{label} › #{frame_path}", frame_path, page: page, frame: frame_id, depth: depth + 1)
      end
      leaks
    end

    def text_leaks(document)
      document.xpath("//body//text()").filter_map do |node|
        next unless node.text.match?(MONEY)
        next if node.ancestors.any? { |a| SKIPPED_TAGS.include?(a.name) || sensitive?(a) }

        "#{describe(node.parent)} shows #{node.text.squish.truncate(60).inspect}"
      end
    end

    def blurred_amounts(document)
      document.css("body .privacy-sensitive").count { |element| "#{element.text}#{element["value"]}".match?(/\d/) }
    end

    def attribute_leaks(document)
      document.css(SHOWN_ATTRIBUTES.map { |name| "[#{name}]" }.join(", ")).filter_map do |element|
        attribute = SHOWN_ATTRIBUTES.find { |name| element[name].to_s.match?(MONEY) }
        next unless attribute
        next if sensitive?(element) || element.ancestors.any? { |a| sensitive?(a) }

        "#{describe(element)} #{attribute}=#{element[attribute].squish.truncate(60).inspect}"
      end
    end

    def sensitive?(element)
      element.respond_to?(:classes) && element.classes.include?("privacy-sensitive")
    end

    def lazy_frames(document)
      document.css("turbo-frame[src]").filter_map do |frame|
        src = frame["src"]
        [ frame["id"], src ] if src.start_with?("/")
      end.uniq
    end

    def describe(element)
      [ element.name, element["id"] && "##{element["id"]}", element["class"] && ".#{element["class"].split.first(4).join(".")}" ].compact.join
    end
end
