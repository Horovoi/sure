# Converts goal amounts by the fork's nearest-rate rule (ExchangeRate.find_rate): the
# day's rate, else the latest stored one before it, else the earliest after it.
#
# One instance is shared by every goal prepared for a page, and it remembers missing
# rates too, so a pair without a rate is looked up once per page, not once per balance,
# row and status pill. It never converts at 1: with no usable rate it raises
# Money::ConversionError, and the goal decides whether to leave the amount out (reads)
# or refuse the write.
class Goal::CurrencyConverter
  def initialize
    @rates = {}
  end

  def convert(money, to:, date: Date.current)
    to = Money::Currency.new(to).iso_code
    from = money.currency.iso_code
    return money if from == to
    return Money.new(0, to) if money.zero?

    Money.new(money.amount * rate_for(from, to, date.to_date), to)
  end

  private
    def rate_for(from, to, date)
      key = [ from, to, date ]
      @rates[key] = ExchangeRate.find_rate(from: from, to: to, date: date)&.rate unless @rates.key?(key)

      rate = @rates[key]
      raise Money::ConversionError.new(from_currency: from, to_currency: to, date: date) unless ExchangeRate.valid_rate?(rate)

      rate.to_d
    end
end
