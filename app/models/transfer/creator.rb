class Transfer::Creator
  def initialize(family:, source_account_id:, destination_account_id:, date:, amount:)
    @family = family
    @source_account = family.accounts.find(source_account_id) # early throw if not found
    @destination_account = family.accounts.find(destination_account_id) # early throw if not found
    @date = date
    @amount = amount.to_d
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

    if inflow_converted_money.nil?
      transfer.errors.add(:base, :missing_exchange_rate, from: source_account.currency, to: destination_account.currency)
      return transfer
    end

    if transfer.save
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

    # If destination account has different currency, its transaction shows up as converted at
    # the nearest-rate rule. nil when the pair has no rate at all.
    def inflow_converted_money
      return @inflow_converted_money if defined?(@inflow_converted_money)

      @inflow_converted_money = ExchangeRate.convert_or_leave_out(
        Money.new(amount.abs, source_account.currency),
        to: destination_account.currency,
        date: date.presence || Date.current,
        source: "Transfer::Creator",
        family: family
      )
    end

    def name_prefix
      if destination_account.liability?
        "Payment"
      else
        "Transfer"
      end
    end
end
