class Transfer::Creator
  def initialize(family:, source_account_id:, destination_account_id:, date:, amount:)
    @family = family
    @source_account = family.accounts.find(source_account_id) # early throw if not found
    @destination_account = family.accounts.find(destination_account_id) # early throw if not found
    @date = date
    @amount = amount.to_d
  end

  # The legs' kinds (and the Investment Contributions category) are set by Transfer's after_create.
  def create
    transfer = Transfer.new(
      inflow_transaction: inflow_transaction,
      outflow_transaction: outflow_transaction,
      status: "confirmed"
    )

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
          amount: inflow_converted_money.amount.abs * -1,
          currency: destination_account.currency,
          date: date,
          name: name,
          user_modified: true, # Protect from provider sync claiming this entry
        )
      )
    end

    # If destination account has different currency, its transaction should show up as converted
    # Future improvement: instead of a 1:1 conversion fallback, add a UI/UX flow for missing rates
    def inflow_converted_money
      Money.new(amount.abs, source_account.currency)
           .exchange_to(
             destination_account.currency,
             date: date,
             fallback_rate: 1.0
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
