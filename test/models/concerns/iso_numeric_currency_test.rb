require "test_helper"

class IsoNumericCurrencyTest < ActiveSupport::TestCase
  class Reader
    include IsoNumericCurrency

    def read(numeric) = [ alpha_currency_code(numeric), minor_unit_divisor(alpha_currency_code(numeric)) ]
  end

  test "maps numeric codes to alphabetic codes" do
    assert_equal "UAH", IsoNumericCurrency.alpha_code(980)
    assert_equal "USD", IsoNumericCurrency.alpha_code("840")
    assert_equal "EUR", IsoNumericCurrency.alpha_code(978)
    assert_equal "AUD", IsoNumericCurrency.alpha_code("36")
    assert_nil IsoNumericCurrency.alpha_code(nil)
    assert_nil IsoNumericCurrency.alpha_code(1)
  end

  test "minor unit divisors" do
    assert_equal 100, IsoNumericCurrency.divisor("UAH")
    assert_equal 1, IsoNumericCurrency.divisor("JPY")
    assert_equal 100, IsoNumericCurrency.divisor(nil)
    assert_equal 100, IsoNumericCurrency.divisor("XXZ")
  end

  test "the concern exposes the same lookups to a provider" do
    assert_equal [ "UAH", 100 ], Reader.new.read(980)
  end
end
