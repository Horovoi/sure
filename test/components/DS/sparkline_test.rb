require "test_helper"

class DS::SparklineTest < ViewComponent::TestCase
  SERIES = [
    [ Date.new(2026, 1, 1), 100 ],
    [ Date.new(2026, 2, 1), 0 ],
    [ Date.new(2026, 3, 1), 50 ],
    [ Date.new(2026, 4, 1), 100 ]
  ].freeze

  test "renders a labelled svg with one dot per point" do
    render_inline(DS::Sparkline.new(series: SERIES, aria_label: "Payment history"))

    assert_selector "svg[role='img'][aria-label='Payment history'].w-full.text-success"
    assert_selector "svg polyline", count: 1
    assert_selector "svg circle", count: 4
  end

  test "a zero value gets a hollow dot" do
    render_inline(DS::Sparkline.new(series: SERIES, aria_label: "Payment history"))

    assert_selector "circle[fill='none']", count: 1
    assert_selector "circle[fill='currentColor']", count: 3
  end

  test "labels every other point" do
    render_inline(DS::Sparkline.new(series: SERIES, aria_label: "Payment history"))

    assert_selector "svg text", count: 2
    assert_selector "svg text", text: "Jan"
    assert_selector "svg text", text: "Mar"
  end

  test "scales points to the peak and pins it to the top of the value band" do
    sparkline = DS::Sparkline.new(series: SERIES, aria_label: "x")
    ys = sparkline.points.map { |_x, y, _value| y }

    assert_in_delta DS::Sparkline::BASELINE_Y - DS::Sparkline::VALUE_HEIGHT, ys.first, 0.001
    assert_in_delta DS::Sparkline::BASELINE_Y, ys.second, 0.001
  end

  test "a single point and an all-zero series do not divide by zero" do
    single = DS::Sparkline.new(series: [ [ Date.new(2026, 1, 1), 0 ] ], aria_label: "x")

    assert_equal 1, single.points.size
    assert single.points.first.first(2).all?(&:finite?)
  end
end
