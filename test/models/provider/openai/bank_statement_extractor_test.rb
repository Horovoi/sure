require "test_helper"

class Provider::Openai::BankStatementExtractorTest < ActiveSupport::TestCase
  setup do
    @extractor = Provider::Openai::BankStatementExtractor.new(client: nil, pdf_content: nil, model: "gpt-test")
  end

  test "numbers stay as they are" do
    assert_equal(-12.5, parse(-12.5))
    assert_equal 1234.56, parse(BigDecimal("1234.56"))
    assert_nil parse(nil)
  end

  test "amounts copied as statement text keep their decimals" do
    {
      "-1 234,56" => -1234.56,
      "-1 234,56" => -1234.56,
      "45 000,00" => 45000.0,
      "1.234,56" => 1234.56,
      "-1,234.56" => -1234.56,
      "12,50" => 12.5,
      "-89.00" => -89.0,
      "−12,50" => -12.5,
      "(12.50)" => -12.5,
      "1,234" => 1234.0,
      "1.234.567" => 1234567.0,
      "-420,00 UAH" => -420.0,
      "₴ 1 359,00" => 1359.0
    }.each do |text, expected|
      assert_equal expected, parse(text), "parsing #{text.inspect}"
    end
  end

  test "a statement row in Ukrainian format is normalized with the right amount" do
    rows = @extractor.send(:normalize_transactions, [ { "date" => "2026-10-07", "description" => "Сільпо", "amount" => "-1 234,56" } ])

    assert_equal [ { date: "2026-10-07", amount: -1234.56, name: "Сільпо", category: nil, notes: nil } ], rows
  end

  private
    def parse(value)
      @extractor.send(:parse_amount, value)
    end
end
