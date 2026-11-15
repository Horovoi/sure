require "test_helper"

class AccountableSparklinesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "should get show for depository" do
    get accountable_sparkline_url("depository")
    assert_response :success
  end

  test "show renders an empty series without a trend" do
    Rails.cache.clear
    Balance::ChartSeriesBuilder.any_instance.expects(:balance_series).returns(empty_series)

    get accountable_sparkline_url("depository")

    assert_response :success
    assert_select "p.font-mono", count: 0
  end

  test "show renders a zero-base series without an infinite percentage" do
    Rails.cache.clear
    Balance::ChartSeriesBuilder.any_instance.expects(:balance_series).returns(zero_base_series)

    get accountable_sparkline_url("depository")

    assert_response :success
    assert_select "[data-controller='time-series-chart']", count: 1
    assert_select "p.font-mono", count: 0
  end

  private
    def empty_series
      Series.new(start_date: 1.day.ago.to_date, end_date: Date.current, interval: "1 day", values: [])
    end

    # Previous value zero: the trend percentage is infinite
    def zero_base_series
      Series.new(
        start_date: 1.day.ago.to_date,
        end_date: Date.current,
        interval: "1 day",
        values: [
          Series::Value.new(date: 1.day.ago.to_date, date_formatted: "", value: Money.new(0, "UAH"), trend: Trend.new(current: Money.new(0, "UAH"), previous: Money.new(0, "UAH"))),
          Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(100, "UAH"), trend: Trend.new(current: Money.new(100, "UAH"), previous: Money.new(0, "UAH")))
        ]
      )
    end
end
