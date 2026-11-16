require "test_helper"

class PrivacyHelperTest < ActionView::TestCase
  test "wraps each amount in prose and leaves the words readable" do
    html = privacy_money_text("4 transactions, average $33, $8 a day")

    assert_equal '4 transactions, average <span class="privacy-sensitive">$33</span>, <span class="privacy-sensitive">$8</span> a day', html
  end

  test "takes signs, grouping and a currency symbol after the number" do
    assert_equal [ "-$1,234.56" ], blurred(privacy_money_text("Balance -$1,234.56."))
    assert_equal [ "1 234,56 €" ], blurred(privacy_money_text("Total 1 234,56 € left"))
    assert_equal [ "₴500" ], blurred(privacy_money_text("Goal ₴500"))
    assert_equal [ "12 500,00 ₴" ], blurred(privacy_money_text("Spent 12 500,00 ₴ in May"))
  end

  test "leaves numbers without a currency alone" do
    assert_equal "15 remaining days, 12%", privacy_money_text("15 remaining days, 12%")
  end

  test "escapes the text and passes html-safe text through" do
    assert_equal '&lt;b&gt;<span class="privacy-sensitive">$5</span>&lt;/b&gt;', privacy_money_text("<b>$5</b>")

    safe = "<em>$5</em>".html_safe
    assert_same safe, privacy_money_text(safe)
  end

  test "wraps amounts in the text of rendered html, not in code" do
    html = privacy_money_html("<p>You spent <strong>$1,234.56</strong> on food</p><pre><code>$99</code></pre>".html_safe)
    fragment = Nokogiri::HTML5.fragment(html)

    assert_equal [ "$1,234.56" ], fragment.css(".privacy-sensitive").map(&:text)
    assert_equal "$1,234.56", fragment.at_css("strong > span.privacy-sensitive").text
    assert_equal "$99", fragment.at_css("pre code").text
  end

  test "escapes plain text given as html" do
    assert_equal '&lt;script&gt;<span class="privacy-sensitive">$1</span>&lt;/script&gt;', privacy_money_html("<script>$1</script>")
  end

  private
    def blurred(html)
      Nokogiri::HTML5.fragment(html).css(".privacy-sensitive").map(&:text)
    end
end
