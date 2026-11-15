require "test_helper"

class Assistant::Function::GetSubscriptionsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.update!(currency: "UAH")
    @family.recurring_transactions.destroy_all
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", rate: 41.5, date: Date.current)
    @fn = Assistant::Function::GetSubscriptions.new(@user)

    @netflix = row(merchant: merchants(:netflix), amount: 15.99, currency: "USD", state: "subscription", next_date: 5.days.from_now)
    @gym = row(name: "Gym", amount: 1200, currency: "UAH", state: "subscription", next_date: 20.days.from_now)
    @domain = row(name: "Domain", amount: 600, currency: "UAH", state: "subscription", billing_cycle: "yearly", expected_month: 3, next_date: 100.days.from_now)
    @paused = row(name: "Old magazine", amount: 100, currency: "UAH", state: "subscription", status: "inactive", next_date: 3.days.from_now)
    @suggested = row(name: "Spotify", amount: 199, currency: "UAH", state: "suggested", next_date: 8.days.from_now)
    @dismissed = row(name: "Car wash", amount: 300, currency: "UAH", state: "dismissed", next_date: 9.days.from_now)
    @rent = row(name: "Rent", amount: 20_000, currency: "UAH", state: "pattern", manual: true, next_date: 2.days.from_now)
    @pattern = row(name: "Coffee", amount: 80, currency: "UAH", state: "pattern", next_date: 1.day.from_now)
  end

  test "is a read tool" do
    assert_equal :read, @fn.scope_tag
    assert @fn.class.read_only?
  end

  test "active lists confirmed active subscriptions with costs in the family currency" do
    result = @fn.call({})

    assert_equal "active", result[:filter]
    assert_equal "UAH", result[:currency]
    assert_equal [ @netflix.id, @gym.id, @domain.id ], result[:subscriptions].map { |s| s[:id] }

    netflix = result[:subscriptions].first
    assert_equal "Netflix", netflix[:name]
    assert_equal "subscription", netflix[:kind]
    assert_equal "USD", netflix[:currency]
    assert_in_delta 15.99, netflix[:amount], 0.001
    assert_in_delta 15.99 * 41.5, netflix[:monthly_cost_in_family_currency], 0.01

    domain = result[:subscriptions].last
    assert_in_delta 50.0, domain[:monthly_cost_in_family_currency], 0.01
  end

  test "totals sum the active subscriptions in UAH, a yearly one as a twelfth" do
    totals = @fn.call({})[:totals]

    assert_equal 3, totals[:active_count]
    assert_equal "UAH", totals[:currency]
    monthly_bills = 15.99 * 41.5 + 1200
    assert_in_delta monthly_bills + 50, totals[:monthly], 0.01
    assert_in_delta monthly_bills * 12 + 600, totals[:yearly], 0.1
    assert_nil totals[:left_out_currencies]
  end

  test "a currency with no rate is left out of the totals and named, never counted at 1" do
    row(name: "Swiss thing", amount: 10, currency: "CHF", state: "subscription", next_date: 4.days.from_now)

    totals = @fn.call({})[:totals]

    assert_equal [ "CHF" ], totals[:left_out_currencies]
    assert_in_delta 15.99 * 41.5 + 1200 + 50, totals[:monthly], 0.01
  end

  test "each filter lists its kind" do
    assert_equal [ @paused.id ], ids_for("paused")
    assert_equal [ @suggested.id ], ids_for("suggested")
    assert_equal [ @dismissed.id ], ids_for("dismissed")
    assert_equal [ @rent.id ], ids_for("other_recurring")

    all = ids_for("all")
    assert_equal [ @netflix, @gym, @domain, @paused, @suggested, @dismissed, @rent ].map(&:id).sort, all.sort
    assert_not_includes all, @pattern.id
  end

  test "an other recurring row is named as such" do
    rent = @fn.call({ "filter" => "other_recurring" })[:subscriptions].first

    assert_equal "other_recurring", rent[:kind]
    assert_equal "active", rent[:status]
  end

  test "upcoming_days keeps the active rows that bill within that window" do
    result = @fn.call({ "filter" => "all", "upcoming_days" => 10 })

    assert_equal [ @rent.id, @netflix.id, @suggested.id, @dismissed.id ], result[:subscriptions].map { |s| s[:id] }
    assert_not_includes result[:subscriptions].map { |s| s[:id] }, @paused.id
  end

  test "a due subscription says so" do
    @gym.update!(next_expected_date: Date.current)

    gym = @fn.call({})[:subscriptions].find { |s| s[:id] == @gym.id }

    assert_equal true, gym[:due]
  end

  test "one row by id, of any kind" do
    result = @fn.call({ "id" => @suggested.id })

    assert_equal @suggested.id, result.dig(:subscription, :id)
    assert_equal "suggested", result.dig(:subscription, :kind)
  end

  test "an unknown id returns an error and a hint" do
    [ SecureRandom.uuid, "not-a-uuid" ].each do |id|
      result = @fn.call({ "id" => id })

      assert_equal "not_found", result[:error]
      assert_includes result[:hint], "get_subscriptions"
    end
  end

  test "another family's row is not found" do
    other = families(:empty).recurring_transactions.create!(
      name: "Theirs", amount: 5, currency: "USD", expected_day_of_month: 1,
      last_occurrence_date: Date.current, next_expected_date: 3.days.from_now, subscription_state: "subscription"
    )

    assert_equal "not_found", @fn.call({ "id" => other.id })[:error]
    assert_not_includes ids_for("all"), other.id
  end

  test "an unknown filter is an argument error" do
    assert_equal "invalid_filter", @fn.call({ "filter" => "everything" })[:error]
    assert_equal "invalid_upcoming_days", @fn.call({ "upcoming_days" => 5000 })[:error]
  end

  private
    def ids_for(filter)
      @fn.call({ "filter" => filter })[:subscriptions].map { |s| s[:id] }
    end

    def row(amount:, currency:, state:, next_date:, name: nil, merchant: nil, status: "active", manual: false, billing_cycle: "monthly", expected_month: nil)
      @family.recurring_transactions.create!(
        name: name, merchant: merchant, amount: amount, currency: currency,
        expected_day_of_month: next_date.to_date.day, expected_month: expected_month,
        last_occurrence_date: 1.month.ago.to_date, next_expected_date: next_date.to_date,
        status: status, subscription_state: state, manual: manual, billing_cycle: billing_cycle
      )
    end
end
