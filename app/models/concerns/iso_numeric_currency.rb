# Translates ISO 4217 numeric currency codes into the alphabetic codes Sure stores.
#
# Most providers report currencies as "UAH"/"USD", which CurrencyNormalizable handles
# directly. Some (monobank) report the numeric code instead (980, 840), so those values
# are mapped before parse_currency sees them; it rejects anything that is not three
# letters. Amounts from the same APIs arrive in minor units, so the minor-unit divisor
# is here too rather than a hard-coded 100 (JPY, KRW and others use 1).
#
#   IsoNumericCurrency.alpha_code(980) # => "UAH"
#   IsoNumericCurrency.divisor("UAH")  # => 100
module IsoNumericCurrency
  extend ActiveSupport::Concern

  class << self
    # Memoized { "980" => "UAH" } map built from Sure's currency table. Built lazily so
    # the YAML is only read when a provider needs a numeric lookup.
    def alpha_by_numeric
      @alpha_by_numeric ||= Money::Currency.all.each_value.with_object({}) do |currency_data, map|
        numeric = currency_data["iso_numeric"].to_s.strip
        iso_code = currency_data["iso_code"].to_s.strip
        next if numeric.blank? || iso_code.blank?

        map[numeric.rjust(3, "0")] ||= iso_code.upcase
      end.freeze
    end

    # @param numeric_code [String, Integer, nil] ISO 4217 numeric code (e.g. 980, "036")
    # @return [String, nil] Alphabetic ISO code (e.g. "UAH"), or nil when unknown
    def alpha_code(numeric_code)
      return nil if numeric_code.blank?

      alpha_by_numeric[normalize(numeric_code)]
    end

    # Divisor that converts an amount in minor units into major units. Falls back to 100
    # for unknown currencies, which is right for every currency monobank supports.
    def divisor(alpha_code)
      return 100 if alpha_code.blank?

      Money::Currency.new(alpha_code).minor_unit_conversion || 100
    rescue Money::Currency::UnknownCurrencyError
      100
    end

    # ISO numeric codes are zero-padded to three digits in currencies.yml ("036").
    def normalize(numeric_code)
      numeric_code.to_s.strip.rjust(3, "0")
    end
  end

  private
    def alpha_currency_code(numeric_code)
      IsoNumericCurrency.alpha_code(numeric_code)
    end

    def minor_unit_divisor(alpha_code)
      IsoNumericCurrency.divisor(alpha_code)
    end

    def normalize_numeric_code(numeric_code)
      IsoNumericCurrency.normalize(numeric_code)
    end
end
