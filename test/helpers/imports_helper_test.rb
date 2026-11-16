require "test_helper"

class ImportsHelperTest < ActionView::TestCase
  test "a sample cell holding a number is blurred before any column is mapped" do
    [ "-1234.56", "25000", "25 000", "(12,50)", "$5", "1 234,56 €", "−40" ].each do |value|
      assert privacy_sensitive_cell?("whatever", value, []), "#{value.inspect} is not blurred"
    end
  end

  test "dates and words in an unmapped column stay readable" do
    [ "01/01/2024", "2024-01-01", "Coffee", "", nil, "Card 1234 payment" ].each do |value|
      assert_not privacy_sensitive_cell?("whatever", value, []), "#{value.inspect} is blurred"
    end
  end

  test "every cell of a mapped amount column is blurred" do
    assert privacy_sensitive_cell?("amount", "n/a", [ "amount" ])
  end
end
