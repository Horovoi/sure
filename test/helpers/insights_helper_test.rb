require "test_helper"

class InsightsHelperTest < ActionView::TestCase
  include PrivacyHelper

  test "insight text blurs the amounts and keeps dates, day counts and percentages readable" do
    html = insight_privacy_text("In the first 30 days your cash of 17,871.67 ₴ could fall to -94,449.29 ₴ around December 16, 2026, 41% more than in September 2026.")
    blurred = Nokogiri::HTML5.fragment(html).css(".privacy-sensitive").map(&:text)

    assert_equal [ "17,871.67 ₴", "-94,449.29 ₴" ], blurred
    assert_includes html, "December 16, 2026"
    assert_includes html, "30 days"
    assert_includes html, "41%"
  end

  test "insight text is escaped" do
    assert_not_includes insight_privacy_text("<b>$5</b>"), "<b>"
  end
end
