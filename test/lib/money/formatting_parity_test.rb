require "test_helper"

# Money#format strings for the owner's currencies under the en locale,
# recorded from the number_to_currency implementation before the fast path
# replaced it. The fast path must produce the same strings byte for byte.
class Money::FormattingParityTest < ActiveSupport::TestCase
  # [currency, amount, format options, expected string]
  EXPECTED = [
    [ "UAH", "0", {}, "0.00 ₴" ],
    [ "UAH", "-0", {}, "0.00 ₴" ],
    [ "UAH", "0.004", {}, "0.00 ₴" ],
    [ "UAH", "-0.004", {}, "0.00 ₴" ],
    [ "UAH", "0.005", {}, "0.01 ₴" ],
    [ "UAH", "-0.005", {}, "-0.01 ₴" ],
    [ "UAH", "0.01", {}, "0.01 ₴" ],
    [ "UAH", "-0.01", {}, "-0.01 ₴" ],
    [ "UAH", "0.5", {}, "0.50 ₴" ],
    [ "UAH", "1", {}, "1.00 ₴" ],
    [ "UAH", "-1", {}, "-1.00 ₴" ],
    [ "UAH", "12.345", {}, "12.35 ₴" ],
    [ "UAH", "-12.345", {}, "-12.35 ₴" ],
    [ "UAH", "999.995", {}, "1,000.00 ₴" ],
    [ "UAH", "-999.995", {}, "-1,000.00 ₴" ],
    [ "UAH", "1234.5", {}, "1,234.50 ₴" ],
    [ "UAH", "-1234.5", {}, "-1,234.50 ₴" ],
    [ "UAH", "1000000", {}, "1,000,000.00 ₴" ],
    [ "UAH", "-1234567.891", {}, "-1,234,567.89 ₴" ],
    [ "UAH", "98765432.1", {}, "98,765,432.10 ₴" ],
    [ "UAH", "123456789012.346", {}, "123,456,789,012.35 ₴" ],
    [ "UAH", "-1234.5", { precision: 0 }, "-1,235 ₴" ],
    [ "UAH", "-1234.5", { unit: "" }, "-1,234.50 " ],
    [ "UAH", "1234.5", { signify_positive: true }, "1,234.50 ₴" ],
    [ "USD", "0", {}, "$0.00" ],
    [ "USD", "-0", {}, "$0.00" ],
    [ "USD", "0.004", {}, "$0.00" ],
    [ "USD", "-0.004", {}, "$0.00" ],
    [ "USD", "0.005", {}, "$0.01" ],
    [ "USD", "-0.005", {}, "-$0.01" ],
    [ "USD", "0.01", {}, "$0.01" ],
    [ "USD", "-0.01", {}, "-$0.01" ],
    [ "USD", "0.5", {}, "$0.50" ],
    [ "USD", "1", {}, "$1.00" ],
    [ "USD", "-1", {}, "-$1.00" ],
    [ "USD", "12.345", {}, "$12.35" ],
    [ "USD", "-12.345", {}, "-$12.35" ],
    [ "USD", "999.995", {}, "$1,000.00" ],
    [ "USD", "-999.995", {}, "-$1,000.00" ],
    [ "USD", "1234.5", {}, "$1,234.50" ],
    [ "USD", "-1234.5", {}, "-$1,234.50" ],
    [ "USD", "1000000", {}, "$1,000,000.00" ],
    [ "USD", "-1234567.891", {}, "-$1,234,567.89" ],
    [ "USD", "98765432.1", {}, "$98,765,432.10" ],
    [ "USD", "123456789012.346", {}, "$123,456,789,012.35" ],
    [ "USD", "-1234.5", { precision: 0 }, "-$1,235" ],
    [ "USD", "-1234.5", { unit: "" }, "-1,234.50" ],
    [ "USD", "1234.5", { signify_positive: true }, "$1,234.50" ],
    [ "EUR", "0", {}, "€0.00" ],
    [ "EUR", "-0", {}, "€0.00" ],
    [ "EUR", "0.004", {}, "€0.00" ],
    [ "EUR", "-0.004", {}, "€0.00" ],
    [ "EUR", "0.005", {}, "€0.01" ],
    [ "EUR", "-0.005", {}, "-€0.01" ],
    [ "EUR", "0.01", {}, "€0.01" ],
    [ "EUR", "-0.01", {}, "-€0.01" ],
    [ "EUR", "0.5", {}, "€0.50" ],
    [ "EUR", "1", {}, "€1.00" ],
    [ "EUR", "-1", {}, "-€1.00" ],
    [ "EUR", "12.345", {}, "€12.35" ],
    [ "EUR", "-12.345", {}, "-€12.35" ],
    [ "EUR", "999.995", {}, "€1,000.00" ],
    [ "EUR", "-999.995", {}, "-€1,000.00" ],
    [ "EUR", "1234.5", {}, "€1,234.50" ],
    [ "EUR", "-1234.5", {}, "-€1,234.50" ],
    [ "EUR", "1000000", {}, "€1,000,000.00" ],
    [ "EUR", "-1234567.891", {}, "-€1,234,567.89" ],
    [ "EUR", "98765432.1", {}, "€98,765,432.10" ],
    [ "EUR", "123456789012.346", {}, "€123,456,789,012.35" ],
    [ "EUR", "-1234.5", { precision: 0 }, "-€1,235" ],
    [ "EUR", "-1234.5", { unit: "" }, "-1,234.50" ],
    [ "EUR", "1234.5", { signify_positive: true }, "€1,234.50" ]
  ].freeze

  test "en strings for UAH, USD and EUR are unchanged" do
    I18n.with_locale(:en) do
      EXPECTED.each do |currency, amount, options, expected|
        actual = Money.new(BigDecimal(amount), currency).format(options)
        assert_equal expected, actual, "#{currency} #{amount} #{options}"
      end
    end
  end

  test "an explicit en locale gives the same strings" do
    I18n.with_locale(:en) do
      EXPECTED.select { |_, _, options, _| options.empty? }.each do |currency, amount, _, expected|
        assert_equal expected, Money.new(BigDecimal(amount), currency).format(locale: :en), "#{currency} #{amount}"
      end
    end
  end

  test "to_s matches format" do
    I18n.with_locale(:en) do
      assert_equal "1,234.50 ₴", Money.new(BigDecimal("1234.5"), "UAH").to_s
    end
  end

  test "the owner's currencies take the fast path under en" do
    I18n.with_locale(:en) do
      %w[UAH USD EUR].each do |currency|
        money = Money.new(BigDecimal("-1234.5"), currency)
        money.expects(:number_to_currency).never
        money.format
      end
    end
  end
end
