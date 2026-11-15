require "test_helper"
require "ostruct"

class MoneyTest < ActiveSupport::TestCase
  test "can create with default currency" do
    value = Money.new(1000)
    assert_equal 1000, value.amount
  end

  test "can create with custom currency" do
    value1 = Money.new(1000, :EUR)
    value2 = Money.new(1000, :eur)
    value3 = Money.new(1000, "eur")
    value4 = Money.new(1000, "EUR")

    assert_equal value1.currency.iso_code, value2.currency.iso_code
    assert_equal value2.currency.iso_code, value3.currency.iso_code
    assert_equal value3.currency.iso_code, value4.currency.iso_code
  end

  test "equality tests amount and currency" do
    assert_equal Money.new(1000), Money.new(1000)
    assert_not_equal Money.new(1000), Money.new(1001)
    assert_not_equal Money.new(1000, :usd), Money.new(1000, :eur)
  end

  test "can compare with zero Numeric" do
    assert_equal Money.new(0), 0
    assert_raises(TypeError) { Money.new(1) == 1 }
  end

  test "can negate" do
    assert_equal (-Money.new(1000)), Money.new(-1000)
  end

  test "can use comparison operators" do
    assert_operator Money.new(1000), :>, Money.new(999)
    assert_operator Money.new(1000), :>=, Money.new(1000)
    assert_operator Money.new(1000), :<, Money.new(1001)
    assert_operator Money.new(1000), :<=, Money.new(1000)
  end

  test "can add and subtract" do
    assert_equal Money.new(1000) + Money.new(1000), Money.new(2000)
    assert_equal Money.new(1000) + 1000, Money.new(2000)
    assert_equal Money.new(1000) - Money.new(1000), Money.new(0)
    assert_equal Money.new(1000) - 1000, Money.new(0)
  end

  test "can multiply" do
    assert_equal Money.new(1000) * 2, Money.new(2000)
    assert_raises(TypeError) { Money.new(1000) * Money.new(2) }
  end

  test "can divide" do
    assert_equal Money.new(1000) / 2, Money.new(500)
    assert_equal Money.new(1000) / Money.new(500), 2
    assert_raise(TypeError) { 1000 / Money.new(2) }
  end

  test "mixing currencies raises in strict mode" do
    usd = Money.new(200, :usd)
    eur = Money.new(180, :eur)

    assert Money.strict_currency?, "development and test run in strict mode"

    %i[+ - / <=> > < >= <=].each do |operator|
      error = assert_raises(Money::CurrencyMismatchError, "#{operator} must not mix currencies") { usd.public_send(operator, eur) }
      assert_equal "USD", error.left_currency
      assert_equal "EUR", error.right_currency
    end
  end

  test "amounts in different currencies are not equal, without raising" do
    assert_not_equal Money.new(100, :usd), Money.new(100, :eur)
    assert_not Money.new(100, :usd) == Money.new(100, :eur)
  end

  test "same currency and Numeric operands are unaffected by strict mode" do
    assert_equal Money.new(380, :eur), Money.new(200, :eur) + Money.new(180, :eur)
    assert_equal Money.new(20, :eur), Money.new(200, :eur) - 180
    assert_operator Money.new(1, :eur), :>, 0
  end

  test "outside strict mode a mismatch is reported once per call site and keeps the old result" do
    strict = Money.strict_currency?
    Money.strict_currency = false
    Money.reset_reported_mismatches!

    results = []
    reports = capture_error_reports(Money::CurrencyMismatchError) do
      3.times { results << Money.new(200, :usd) - Money.new(180, :eur) }
    end

    assert_equal [ Money.new(20, :usd) ] * 3, results
    assert_equal 1, reports.size
    assert_equal 1, DebugLogEntry.where(category: "money", source: "Money#-").count
  ensure
    Money.strict_currency = strict
    Money.reset_reported_mismatches!
  end

  test "mismatch reports keep coming once the per-process memory is full" do
    Money.reset_reported_mismatches!
    Money::REPORTED_MISMATCHES_LIMIT.times { |i| assert Money.first_mismatch_report?([ :-, "USD", "EUR", "site #{i}" ]) }

    assert Money.first_mismatch_report?([ :-, "USD", "EUR", "a new call site" ]), "a new call site must still be reported"
    assert_not Money.first_mismatch_report?([ :-, "USD", "EUR", "a new call site" ])
  ensure
    Money.reset_reported_mismatches!
  end

  test "a conversion error says which rate is missing" do
    error = Money::ConversionError.new(from_currency: "USD", to_currency: "UAH", date: Date.new(2026, 11, 15))

    assert_equal "Couldn't find exchange rate from USD to UAH on 2026-11-15", error.message
  end

  test "operator order does not matter" do
    assert_equal Money.new(1000) + 1000, 1000 + Money.new(1000)
    assert_equal Money.new(1000) - 1000, 1000 - Money.new(1000)
    assert_equal Money.new(1000) * 2, 2 * Money.new(1000)
  end

  test "can get absolute value" do
    assert_equal Money.new(1000).abs, Money.new(1000)
    assert_equal Money.new(-1000).abs, Money.new(1000)
  end

  test "can test if zero" do
    assert Money.new(0).zero?
    assert_not Money.new(1000).zero?
  end

  test "can test if negative" do
    assert Money.new(-1000).negative?
    assert_not Money.new(1000).negative?
  end

  test "can test if positive" do
    assert Money.new(1000).positive?
    assert_not Money.new(-1000).positive?
  end

  test "can format" do
    assert_equal "$1,000.90", Money.new(1000.899).to_s
    assert_equal "€1,000.12", Money.new(1000.12, :eur).to_s
    assert_equal "€ 1.000,12", Money.new(1000.12, :eur).format(locale: :nl)
  end

  test "formats correctly for French locale" do
    # French uses non-breaking spaces (NBSP = \u00A0) between thousands and before currency symbol
    assert_equal "1\u00A0000,12\u00A0€", Money.new(1000.12, :eur).format(locale: :fr)
    assert_equal "1\u00A0000,12\u00A0$", Money.new(1000.12, :usd).format(locale: :fr)
  end

  test "formats correctly for German locale" do
    assert_equal "1.000,12 €", Money.new(1000.12, :eur).format(locale: :de)
    assert_equal "1.000,12 $", Money.new(1000.12, :usd).format(locale: :de)
  end

  test "formats correctly for Spanish locale" do
    assert_equal "1.000,12 €", Money.new(1000.12, :eur).format(locale: :es)
  end

  test "formats correctly for Italian locale" do
    assert_equal "1.000,12 €", Money.new(1000.12, :eur).format(locale: :it)
  end

  test "formats correctly for Portuguese (Brazil) locale" do
    assert_equal "R$ 1.000,12", Money.new(1000.12, :brl).format(locale: :"pt-BR")
  end

  test "formats correctly for Polish locale" do
    # Polish uses space as thousands delimiter, comma as decimal separator, symbol after number
    assert_equal "1 000,12 zł", Money.new(1000.12, :pln).format(locale: :pl)
    assert_equal "1 000,12 €", Money.new(1000.12, :eur).format(locale: :pl)
  end

  test "formats correctly for Turkish locale" do
    # Turkish uses dot as thousands delimiter, comma as decimal separator, symbol after number
    assert_equal "1.000,12 ₺", Money.new(1000.12, :try).format(locale: :tr)
    assert_equal "1.000,12 €", Money.new(1000.12, :eur).format(locale: :tr)
  end

  test "formats correctly for Norwegian Bokmål locale" do
    # Norwegian uses space as thousands delimiter, comma as decimal separator, symbol after number
    assert_equal "1 000,12 kr", Money.new(1000.12, :nok).format(locale: :nb)
    assert_equal "1 000,12 €", Money.new(1000.12, :eur).format(locale: :nb)
  end

  test "formats correctly for Catalan locale" do
    # Catalan uses dot as thousands delimiter, comma as decimal separator, symbol after number
    assert_equal "1.000,12 €", Money.new(1000.12, :eur).format(locale: :ca)
  end

  test "formats correctly for Romanian locale" do
    # Romanian uses dot as thousands delimiter, comma as decimal separator, symbol after number
    assert_equal "1.000,12 Lei", Money.new(1000.12, :ron).format(locale: :ro)
    assert_equal "1.000,12 €", Money.new(1000.12, :eur).format(locale: :ro)
  end

  test "formats correctly for Dutch locale" do
    # Dutch uses dot as thousands delimiter, comma as decimal separator, symbol before number
    assert_equal "€ 1.000,12", Money.new(1000.12, :eur).format(locale: :nl)
    assert_equal "$ 1.000,12", Money.new(1000.12, :usd).format(locale: :nl)
  end

  test "formats correctly for Chinese Simplified locale" do
    # Chinese Simplified uses English-style formatting (comma as thousands delimiter, dot as decimal separator)
    assert_equal "¥1,000.12", Money.new(1000.12, :cny).format(locale: :"zh-CN")
  end

  test "formats correctly for Chinese Traditional locale" do
    # Chinese Traditional uses English-style formatting (comma as thousands delimiter, dot as decimal separator)
    # TWD symbol is prefixed with "TW" to distinguish from other dollar currencies
    assert_equal "TW$1,000.12", Money.new(1000.12, :twd).format(locale: :"zh-TW")
  end

  test "all supported locales can format money without errors" do
    # Ensure all supported locales from LanguagesHelper::SUPPORTED_LOCALES work
    supported_locales = %w[en fr de es tr nb ca ro pt-BR zh-CN zh-TW nl]

    supported_locales.each do |locale|
      locale_sym = locale.to_sym
      # Format with USD and EUR to ensure locale handling works for different currencies
      result_usd = Money.new(1000.12, :usd).format(locale: locale_sym)
      result_eur = Money.new(1000.12, :eur).format(locale: locale_sym)

      assert result_usd.present?, "Locale #{locale} should format USD without errors"
      assert result_eur.present?, "Locale #{locale} should format EUR without errors"
    end
  end

  test "converts currency when rate available" do
    ExchangeRate.expects(:find_or_fetch_rate).returns(OpenStruct.new(rate: 1.2))

    assert_equal Money.new(1000).exchange_to(:eur), Money.new(1000 * 1.2, :eur)
  end

  test "raises when no conversion rate available and no fallback rate provided" do
    ExchangeRate.expects(:find_or_fetch_rate).returns(nil)

    assert_raises Money::ConversionError do
      Money.new(1000).exchange_to(:jpy)
    end
  end

  test "converts currency with a fallback rate" do
    ExchangeRate.expects(:find_or_fetch_rate).returns(nil).twice

    assert_equal 0, Money.new(1000).exchange_to(:jpy, fallback_rate: 0)
    assert_equal Money.new(1000, :jpy), Money.new(1000, :usd).exchange_to(:jpy, fallback_rate: 1)
  end

  test "exchange_to without a rate raises a ConversionError naming both currencies and the date" do
    ExchangeRate.stubs(:find_rate).returns(nil)

    error = assert_raises(Money::ConversionError) do
      Money.new(10, "PLN").exchange_to("UAH", date: Date.new(2026, 11, 1))
    end

    assert_equal "PLN", error.from_currency
    assert_equal "UAH", error.to_currency
    assert_match "from PLN to UAH on 2026-11-01", error.message
  end
end
