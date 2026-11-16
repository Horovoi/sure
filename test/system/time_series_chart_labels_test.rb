require "application_system_test_case"

# The y-guide labels (max, middle, min) and the end value label are both
# right-aligned at the end of the chart. When the end value sits near a guide,
# the guide label used to be drawn on top of it (the dashboard Net Worth card:
# "4,573.80 ₴" over "-₴8.51k").
class TimeSeriesChartLabelsTest < ApplicationSystemTestCase
  CHART_ID = "labelsTestChart"

  setup do
    sign_in users(:family_admin)
  end

  test "no guide label is drawn over the end value label" do
    # The owner's 30-day net worth: a dip to -50k, a jump to +33k and an end
    # at 4.5k, a little above the middle guide (-8.5k)
    amounts = [ -15_794.68, -22_000, -30_500, -50_450, 25_000, 33_430, 31_000, 29_500, 28_000, 4_573.80 ]

    [ [ 480, 208 ], [ 900, 480 ] ].each do |width, height|
      mount_chart(amounts, width: width, height: height)

      # The start label comes first, the end label second
      end_label = all("##{CHART_ID} g.endpoint-marker.label text.text-primary", count: 2).last.native.rect
      guides = all("##{CHART_ID} text.fg-gray", wait: 0)
      assert guides.any?, "the chart draws guide labels at #{width}x#{height}"

      guides.each do |guide|
        rect = guide.native.rect
        overlap = rect.y < end_label.y + end_label.height && end_label.y < rect.y + rect.height &&
          rect.x < end_label.x + end_label.width && end_label.x < rect.x + rect.width
        assert_not overlap, "guide label #{guide.text} is drawn over the end label at #{width}x#{height}"
      end
    end
  end

  test "a 32px sparkline draws its line left to right inside its box" do
    page.execute_script(<<~JS, values_json([ 100, 120, 90, 140, 150 ]))
      const [json] = arguments;
      const chart = document.createElement("div");
      chart.id = "sparklineTestChart";
      chart.style.width = "32px";
      chart.style.height = "20px";
      chart.dataset.timeSeriesChartDataValue = json;
      chart.dataset.timeSeriesChartUseLabelsValue = "false";
      chart.dataset.timeSeriesChartUseTooltipValue = "false";
      chart.dataset.controller = "time-series-chart";
      document.querySelector("main").prepend(chart);
    JS

    assert_selector "#sparklineTestChart svg path[fill='none']"
    # The labelled paddings are wider than this chart: the x scale used to run
    # backwards, from right to left
    first_x, last_x = page.evaluate_script(<<~'JS')
      (() => {
        const d = document.querySelector("#sparklineTestChart svg path[fill='none']").getAttribute("d");
        const xs = d.match(/[ML]\s*-?[\d.]+/g).map((p) => parseFloat(p.slice(1)));
        return [xs[0], xs[xs.length - 1]];
      })()
    JS
    assert first_x < last_x, "the line runs from #{first_x} to #{last_x}"
    assert first_x >= 0 && last_x <= 24, "the line #{first_x}..#{last_x} leaves the 24px plot"
    assert_no_selector "#sparklineTestChart .intermediate-tick"
  end

  private
    def values_json(amounts)
      start = Date.new(2026, 10, 17)
      values = amounts.each_with_index.map do |amount, index|
        {
          date: (start + index.days).iso8601,
          date_formatted: (start + index.days).iso8601,
          value: { amount: amount.to_s, currency: "UAH", formatted: "#{amount} ₴" },
          trend: { color: "var(--color-success)", value: { amount: "0" }, current: { amount: amount.to_s }, previous: { amount: "0" } }
        }
      end
      { values: values, trend: { color: "var(--color-success)" } }.to_json
    end


    def mount_chart(amounts, width:, height:)
      start = Date.new(2026, 10, 17)
      values = amounts.each_with_index.map do |amount, index|
        {
          date: (start + (index * 3).days).iso8601,
          date_formatted: (start + (index * 3).days).iso8601,
          value: { amount: amount.to_s, currency: "UAH", formatted: "#{format("%.2f", amount)} ₴" },
          trend: { color: "var(--color-success)", value: { amount: "0" }, current: { amount: amount.to_s }, previous: { amount: "0" } }
        }
      end
      data = { values: values, trend: { color: "var(--color-success)" } }

      page.execute_script(<<~JS, CHART_ID, data.to_json, width, height)
        const [id, json, width, height] = arguments;
        document.getElementById(id)?.remove();
        const chart = document.createElement("div");
        chart.id = id;
        chart.style.width = `${width}px`;
        chart.style.height = `${height}px`;
        chart.dataset.timeSeriesChartDataValue = json;
        chart.dataset.timeSeriesChartEndpointMarkersValue = "true";
        chart.dataset.timeSeriesChartShowYGuidesValue = "true";
        chart.dataset.controller = "time-series-chart";
        document.querySelector("main").prepend(chart);
      JS

      assert_selector "##{CHART_ID} svg g.endpoint-marker.label", count: 2
    end
end
