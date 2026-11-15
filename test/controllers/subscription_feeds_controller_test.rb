require "test_helper"

class SubscriptionFeedsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:dylan_family)
    @family.recurring_transactions.destroy_all
    @token = @family.enable_subscriptions_feed!
  end

  def create_feed_row(**attrs)
    @family.recurring_transactions.create!({
      name: "Gym", amount: 30, currency: "USD", expected_day_of_month: Date.current.day.clamp(1, 28),
      last_occurrence_date: Date.current, next_expected_date: Date.current + 5, status: "active",
      subscription_state: "subscription", billing_cycle: "monthly"
    }.merge(attrs))
  end

  # The feed counts days in the family's time zone
  def feed_today
    Time.use_zone(ActiveSupport::TimeZone[@family.timezone.to_s] || Time.zone) { Date.current }
  end

  def feed_events(body)
    body.scan("BEGIN:VEVENT").size
  end

  # Content lines unfolded (RFC 5545 3.1)
  def unfolded(body)
    body.gsub("\r\n ", "")
  end

  test "an unknown token is not found" do
    get subscriptions_feed_url(token: "not-a-real-token")

    assert_response :not_found
  end

  test "a disabled feed is not found" do
    @family.disable_subscriptions_feed!

    get subscriptions_feed_url(token: @token)

    assert_response :not_found
  end

  test "a reset feed no longer answers on the old token" do
    new_token = @family.reset_subscriptions_feed!

    get subscriptions_feed_url(token: @token)
    assert_response :not_found

    get subscriptions_feed_url(token: new_token)
    assert_response :success
  end

  test "the feed needs no session and returns a calendar" do
    create_feed_row

    get subscriptions_feed_url(token: @token)

    assert_response :success
    assert_equal "text/calendar", response.media_type
    assert response.body.start_with?("BEGIN:VCALENDAR\r\n")
    assert response.body.end_with?("END:VCALENDAR\r\n")
    assert_includes response.body, "VERSION:2.0\r\n"
  end

  test "each upcoming date in the next 90 days is one all-day event" do
    row = create_feed_row(next_expected_date: feed_today + 5)

    get subscriptions_feed_url(token: @token)

    expected = []
    date = row.next_expected_date
    while date <= feed_today + RecurringTransaction::IcalFeed::DAYS
      expected << date
      date = row.calculate_next_expected_date(date)
    end

    assert_equal expected.size, feed_events(response.body)
    assert_includes response.body, "DTSTART;VALUE=DATE:#{expected.first.strftime("%Y%m%d")}\r\n"
    assert_includes response.body, "DTEND;VALUE=DATE:#{(expected.first + 1).strftime("%Y%m%d")}\r\n"
    assert_includes response.body, "UID:#{row.id}-#{expected.first.strftime("%Y%m%d")}@sure\r\n"
  end

  test "a yearly subscription outside the window has no event" do
    create_feed_row(billing_cycle: "yearly", expected_month: (Date.current + 200).month,
      expected_day_of_month: 1, next_expected_date: Date.current + 200)

    get subscriptions_feed_url(token: @token)

    assert_equal 0, feed_events(response.body)
  end

  test "paused rows, detected patterns, suggestions and dismissed rows are left out" do
    create_feed_row(name: "Paused", status: "inactive", inactive_reason: "user")
    create_feed_row(name: "Pattern", subscription_state: "pattern")
    create_feed_row(name: "Suggested", subscription_state: "suggested")
    create_feed_row(name: "Dismissed", subscription_state: "dismissed", dismissed_at: 1.day.ago)
    create_feed_row(name: "Rent", subscription_state: "pattern", manual: true, amount: 800, next_expected_date: Date.current + 85)

    get subscriptions_feed_url(token: @token)

    body = unfolded(response.body)
    assert_equal 1, feed_events(body)
    assert_includes body, "SUMMARY:Rent: $800.00"
    %w[Paused Pattern Suggested Dismissed].each { |name| assert_not_includes body, "SUMMARY:#{name}" }
  end

  test "another family's rows are not in the feed" do
    families(:empty).recurring_transactions.create!(
      name: "Elsewhere", amount: 10, currency: "USD", expected_day_of_month: 1,
      last_occurrence_date: Date.current, next_expected_date: Date.current + 3, status: "active",
      subscription_state: "subscription", billing_cycle: "monthly"
    )

    get subscriptions_feed_url(token: @token)

    assert_not_includes response.body, "Elsewhere"
  end

  test "commas, semicolons, backslashes and newlines in text are escaped" do
    create_feed_row(name: "Gym, pool; sauna\\spa\nannual", next_expected_date: Date.current + 85)

    get subscriptions_feed_url(token: @token)

    body = unfolded(response.body)
    assert_includes body, "SUMMARY:Gym\\, pool\\; sauna\\\\spa\\nannual: $30.00\r\n"
    assert_not_includes body, "pool; sauna"
  end

  test "long lines are folded at 75 octets" do
    create_feed_row(name: "Ж" * 60, next_expected_date: Date.current + 85)

    get subscriptions_feed_url(token: @token)

    response.body.split("\r\n").each do |line|
      assert_operator line.bytesize, :<=, 75
      assert line.valid_encoding?
    end
    assert_includes unfolded(response.body), "SUMMARY:#{"Ж" * 60}: $30.00"
  end

  test "income rows show a plus sign" do
    create_feed_row(name: "Salary", amount: -1000, subscription_state: "pattern", manual: true, next_expected_date: Date.current + 85)

    get subscriptions_feed_url(token: @token)

    assert_includes unfolded(response.body), "SUMMARY:Salary: +$1,000.00"
  end
end
