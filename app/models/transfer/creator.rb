class Transfer::Creator
  # exchange_rate and destination_amount apply only when the two accounts differ in
  # currency, and the user gives at most one of them (the form's two tabs):
  # - exchange_rate: the bank's rate from the source currency into the destination one;
  #   the inflow is amount * rate.
  # - destination_amount: what arrived, in the destination currency; the inflow is exactly
  #   that amount.
  # With neither, the inflow converts at the nearest-rate rule.
  #
  # source_fee and destination_fee (decision 21) are what the bank charged, each in its
  # account's currency. They become linked expenses in the 'Fees' category; the legs keep
  # the principal. Blank or zero means no fee.
  def initialize(family:, source_account_id:, destination_account_id:, date:, amount:, exchange_rate: nil, destination_amount: nil, source_fee: nil, destination_fee: nil)
    @family = family
    @source_account = family.accounts.find(source_account_id) # early throw if not found
    @destination_account = family.accounts.find(destination_account_id) # early throw if not found
    @date = date
    @amount = amount.to_d
    @exchange_rate_input = exchange_rate
    @destination_amount_input = destination_amount
    @fee_inputs = { "source" => source_fee, "destination" => destination_fee }
  end

  # The legs' kinds (and the Investment Contributions category) are set by Transfer's after_create.
  # With no exchange rate at all between the two accounts' currencies the transfer is not
  # saved and carries a validation error, rather than moving the amount at 1:1.
  def create
    transfer = Transfer.new(
      inflow_transaction: inflow_transaction,
      outflow_transaction: outflow_transaction,
      status: "confirmed"
    )

    if (error = amount_error || conversion_error || fee_error)
      transfer.errors.add(:base, *error)
      return transfer
    end

    saved = Transfer.transaction do
      next false unless transfer.save

      fees.each { |side, fee| transfer.set_fee!(side: side, amount: fee) }
      true
    end

    if saved
      source_account.sync_later
      destination_account.sync_later
    end

    transfer
  end

  private
    attr_reader :family, :source_account, :destination_account, :date, :amount

    def outflow_transaction
      name = "#{name_prefix} to #{destination_account.name}"

      Transaction.new(
        entry: source_account.entries.build(
          amount: amount.abs,
          currency: source_account.currency,
          date: date,
          name: name,
          user_modified: true, # Protect from provider sync claiming this entry
        )
      )
    end

    def inflow_transaction
      name = "#{name_prefix} from #{source_account.name}"

      Transaction.new(
        entry: destination_account.entries.build(
          # Without a rate the transfer is never saved (see #create); the form keeps the amount
          amount: (inflow_converted_money || Money.new(amount, source_account.currency)).amount.abs * -1,
          currency: destination_account.currency,
          date: date,
          name: name,
          user_modified: true, # Protect from provider sync claiming this entry
        )
      )
    end

    # side => fee amount above zero
    def fees
      @fee_inputs.filter_map do |side, value|
        fee = UserDecimal.parse(value)
        [ side, fee ] if fee&.positive?
      end
    end

    def fee_error
      invalid = @fee_inputs.values.any? do |value|
        next false if value.blank?

        fee = UserDecimal.parse(value)
        fee.nil? || fee.negative?
      end

      [ :invalid_fee ] if invalid
    end

    def cross_currency?
      source_account.currency != destination_account.currency
    end

    # A zero amount (a blank or unreadable form value is 0 too) moves nothing
    def amount_error
      [ :invalid_amount ] if amount.zero?
    end

    # [error key, options] for Transfer#errors, or nil when the inflow can be converted
    def conversion_error
      return unless cross_currency?

      if @exchange_rate_input.present? && @destination_amount_input.present?
        [ :exchange_rate_and_destination_amount ]
      elsif @exchange_rate_input.present? && custom_rate.nil?
        [ :invalid_exchange_rate ]
      elsif @destination_amount_input.present? && destination_amount.nil?
        [ :invalid_destination_amount ]
      elsif inflow_converted_money.nil?
        [ :missing_exchange_rate, { from: source_account.currency, to: destination_account.currency } ]
      end
    end

    # The money that arrives in the destination account. In another currency it is the
    # user's destination amount, else the amount at the user's rate, else the amount at the
    # nearest-rate rule. nil when none of these can convert it.
    def inflow_converted_money
      return @inflow_converted_money if defined?(@inflow_converted_money)

      source_money = Money.new(amount.abs, source_account.currency)

      @inflow_converted_money = if !cross_currency?
        source_money
      elsif @exchange_rate_input.present? || @destination_amount_input.present?
        user_converted_money(source_money)
      else
        ExchangeRate.convert_or_leave_out(
          source_money,
          to: destination_account.currency,
          date: date.presence || Date.current,
          source: "Transfer::Creator",
          family: family
        )
      end
    end

    def user_converted_money(source_money)
      return if @exchange_rate_input.present? && @destination_amount_input.present?

      if @destination_amount_input.present?
        destination_amount && Money.new(destination_amount, destination_account.currency)
      else
        source_money.exchange_to(destination_account.currency, date: date, custom_rate: custom_rate)
      end
    rescue Money::ConversionError
      nil
    end

    def custom_rate
      positive_decimal(@exchange_rate_input)
    end

    def destination_amount
      positive_decimal(@destination_amount_input)
    end

    # A BigDecimal above zero, or nil for anything else
    def positive_decimal(value)
      number = UserDecimal.parse(value)
      number if number&.positive?
    end

    def name_prefix
      if destination_account.liability?
        "Payment"
      else
        "Transfer"
      end
    end
end
