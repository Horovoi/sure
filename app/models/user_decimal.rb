# Reads a number a user typed into a plain text field (an exchange rate, an amount that
# no money field normalized): "41.5", "41,5" and "1 234,56" all read. Returns a finite
# BigDecimal, or nil for blank or unreadable text, so the caller decides what nil means.
module UserDecimal
  module_function

  def parse(value)
    return if value.blank?

    text = value.to_s.strip.gsub(/[[:space:]]/, "")
    # A comma is the decimal separator unless a dot already is ("1,234.5")
    text = text.include?(".") ? text.delete(",") : text.tr(",", ".") unless value.is_a?(Numeric)

    number = BigDecimal(text)
    number if number.finite?
  rescue ArgumentError, TypeError
    nil
  end
end
