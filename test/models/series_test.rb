require "test_helper"

class SeriesTest < ActiveSupport::TestCase
  test "as_json rounds values to the currency's display precision" do
    series = build_series(previous: 100.001, current: 100.004, currency: "UAH")

    values = series.as_json[:values]

    assert_equal BigDecimal("100.0"), values.first[:value].amount
    assert_equal BigDecimal("100.0"), values.last[:value].amount
  end

  test "a sub-kopeck residue reads as no change" do
    series = build_series(previous: 100.001, current: 100.004, currency: "UAH")

    trend = series.as_json[:values].last[:trend]

    # Both amounts format as 100.00 ₴
    assert_equal 0, trend.value.amount
    assert trend.direction.flat?
  end

  test "rounds USD the same way" do
    series = build_series(previous: 0, current: 0.0001, currency: "USD")

    assert_equal 0, series.as_json[:values].last[:value].amount
    assert series.as_json[:values].last[:trend].direction.flat?
  end

  test "rounds the trend at a zero-decimal currency's precision" do
    series = build_series(previous: 1000.4, current: 1000.6, currency: "JPY")

    trend = series.as_json[:values].last[:trend]

    # ¥1,000 -> ¥1,001
    assert_equal 1, trend.value.amount
    assert trend.direction.up?
  end

  test "the series trend is rounded like the values" do
    series = build_series(previous: 0, current: 0.004, currency: "UAH")

    assert series.trend.direction.flat?
    assert_equal 0, series.trend.value.amount
    assert series.trend.percent.finite?
    assert_equal series.trend.as_json, series.as_json[:trend].as_json
  end

  test "leaves the series values themselves exact" do
    series = build_series(previous: 100.001, current: 100.004, currency: "UAH")

    # Insights, goals and the assistant read the values directly
    assert_equal BigDecimal("100.004"), series.values.last.value.amount
    assert_equal BigDecimal("0.003"), series.values.last.trend.value.amount
  end

  test "an infinite percentage serializes as null for the chart" do
    series = build_series(previous: 0, current: 100, currency: "UAH")

    payload = JSON.parse(series.to_json)

    assert_nil payload["trend"]["percent"]
    assert_nil payload["values"].last["trend"]["percent"]
  end

  private
    def build_series(previous:, current:, currency:)
      Series.new(
        start_date: Date.new(2026, 6, 1),
        end_date: Date.new(2026, 6, 2),
        interval: "1 day",
        values: [
          Series::Value.new(
            date: Date.new(2026, 6, 1),
            date_formatted: "June 1, 2026",
            value: Money.new(previous, currency),
            trend: Trend.new(
              current: Money.new(previous, currency),
              previous: Money.new(previous, currency),
              favorable_direction: "up"
            )
          ),
          Series::Value.new(
            date: Date.new(2026, 6, 2),
            date_formatted: "June 2, 2026",
            value: Money.new(current, currency),
            trend: Trend.new(
              current: Money.new(current, currency),
              previous: Money.new(previous, currency),
              favorable_direction: "up"
            )
          )
        ]
      )
    end
end
