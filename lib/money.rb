class Money
  include Comparable, Arithmetic, Formatting
  include ActiveModel::Validations

  class ConversionError < StandardError
    attr_reader :from_currency, :to_currency, :date

    def initialize(from_currency:, to_currency:, date:)
      @from_currency = from_currency
      @to_currency = to_currency
      @date = date

      # Exception#message before super is the class name, so it never stood in for this text
      super("Couldn't find exchange rate from #{from_currency} to #{to_currency} on #{date}")
    end
  end

  # Raised (strict mode) or reported (otherwise) when an operation combines two amounts in
  # different currencies. The operators cannot convert: they do not know which date the
  # rate is for, and that differs per caller (entry date, price date, today). Callers
  # convert with exchange_to (or ExchangeRate.convert_or_leave_out) first.
  class CurrencyMismatchError < StandardError
    attr_reader :left_currency, :right_currency, :operation

    def initialize(left_currency:, right_currency:, operation:)
      @left_currency = left_currency
      @right_currency = right_currency
      @operation = operation

      super("Can't apply #{operation} to #{left_currency} and #{right_currency} amounts; convert one with exchange_to first")
    end
  end

  # Distinct mismatch call sites remembered per process before the memory starts over
  REPORTED_MISMATCHES_LIMIT = 500

  attr_reader :amount, :currency, :store

  validate :source_must_be_of_known_type

  class << self
    def default_currency
      @default ||= Money::Currency.new(:usd)
    end

    def default_currency=(object)
      @default = Money::Currency.new(object)
    end

    # On in development and test (config/initializers/money.rb): mixing currencies raises.
    # Off in production: the mismatch is reported once per call site and the operation
    # keeps its old result, so a page that shows a wrong figure today does not start failing.
    attr_writer :strict_currency

    def strict_currency?
      @strict_currency == true
    end

    # true the first time a mismatch key is seen in this process. Once the memory is full
    # it starts over instead of going quiet, so a long-running process still reports new
    # call sites (a known one may be reported once more).
    def first_mismatch_report?(key)
      @reported_mismatches ||= Concurrent::Set.new
      @reported_mismatches.clear if @reported_mismatches.size >= REPORTED_MISMATCHES_LIMIT

      !@reported_mismatches.add?(key).nil?
    end

    def reset_reported_mismatches!
      @reported_mismatches = nil
    end
  end

  def initialize(obj, currency = Money.default_currency, store: ExchangeRate)
    @source = obj
    @amount = obj.is_a?(Money) ? obj.amount : BigDecimal(obj.to_s)
    @currency = obj.is_a?(Money) ? obj.currency : Money::Currency.new(currency)
    @store = store

    validate!
  end

  # Converts by the nearest-rate rule (ExchangeRate::Provided): the day's rate, else the
  # latest stored one before it, else the earliest after it. With no usable rate it uses
  # fallback_rate when given and raises ConversionError otherwise; callers that total
  # amounts leave such an amount out (ExchangeRate.convert_or_leave_out) rather than
  # passing fallback_rate: 1.
  def exchange_to(other_currency, date: Date.current, fallback_rate: nil)
    iso_code = currency.iso_code
    other_iso_code = Money::Currency.new(other_currency).iso_code

    if iso_code == other_iso_code
      self
    else
      exchange_rate = stored_rate(from: iso_code, to: other_iso_code, date: date) || fallback_rate

      raise ConversionError.new(from_currency: iso_code, to_currency: other_iso_code, date: date) unless exchange_rate

      Money.new(amount * exchange_rate, other_iso_code)
    end
  end

  # Rounded to the precision `format` prints, so a chart drawn from the amount
  # agrees with the label next to it.
  def for_display
    self.class.new(amount.round(currency.default_precision), currency, store: store)
  end

  def as_json
    { amount: amount, currency: currency.iso_code, formatted: format }.as_json
  end

  # Amounts in different currencies are simply not equal; only ordering them (<, >, <=>)
  # needs a conversion
  def ==(other)
    return false if other.is_a?(Money) && currency != other.currency

    super
  end

  def <=>(other)
    raise TypeError, "Money can only be compared with other Money objects except for 0" unless other.is_a?(Money) || other.eql?(0)

    if other.is_a?(Numeric)
      amount <=> other
    else
      ensure_same_currency!(other, :<=>)
      amount_comparison = amount <=> other.amount

      if amount_comparison == 0
        currency <=> other.currency
      else
        amount_comparison
      end
    end
  end

  private
    def ensure_same_currency!(other, operation)
      return if currency == other.currency

      error = CurrencyMismatchError.new(left_currency: currency.iso_code, right_currency: other.currency.iso_code, operation: operation)
      raise error if self.class.strict_currency?

      # Once per call site and process: a sort or a long sync would otherwise report the
      # same mismatch thousands of times
      call_site = caller_locations(2, 1).first&.to_s
      return unless self.class.first_mismatch_report?([ operation, error.left_currency, error.right_currency, call_site ])

      Rails.error.report(error, handled: true, severity: :warning, source: "money", context: { call_site: call_site })
      Rails.logger.warn("[Money] #{error.message} (#{call_site})")
      DebugLogEntry.capture(
        category: "money", level: "warn", message: error.message, source: "Money##{operation}",
        metadata: { left_currency: error.left_currency, right_currency: error.right_currency, call_site: call_site }
      )
    end

    def stored_rate(from:, to:, date:)
      record = if store.respond_to?(:find_rate)
        store.find_rate(from: from, to: to, date: date)
      else
        store.find_or_fetch_rate(from: from, to: to, date: date)
      end

      rate = record&.rate
      rate if rate && rate.to_d.finite? && rate.to_d.positive?
    end

    def source_must_be_of_known_type
      unless @source.is_a?(Money) || @source.is_a?(Numeric) || @source.is_a?(BigDecimal)
        errors.add :source, "must be a Money, Numeric, or BigDecimal"
      end
    end
end
