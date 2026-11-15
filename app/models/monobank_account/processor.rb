# Writes one product's balance and entries into its linked Sure account.
#
# Balance (monobank "balance" includes the credit limit):
#   CreditCard  limit - balance (the debt); available_credit = balance
#   Depository  balance - limit (own funds); jars and FOP accounts have no limit
# It is written as the current anchor through the import adapter.
#
# For an account monobank created (no cut-over), the opening anchor is set once,
# when the history backfill is complete, to the balance before the oldest row.
class MonobankAccount::Processor
  attr_reader :monobank_account

  def initialize(monobank_account)
    @monobank_account = monobank_account
  end

  def process
    account = monobank_account.current_account
    return nil if account.nil?

    adapter = Account::ProviderImportAdapter.new(account)
    write_balance(account, adapter)
    result = MonobankAccount::Transactions::Processor.new(monobank_account, import_adapter: adapter).process
    set_opening_anchor(account)
    result
  end

  private
    def write_balance(account, adapter)
      balance = monobank_account.balance_for(account.accountable_type)
      return if balance.nil?

      adapter.update_balance(balance: balance, cash_balance: balance, source: MonobankEntry::Processor::SOURCE)
      if account.accountable_type == "CreditCard"
        adapter.update_accountable_attributes(attributes: { available_credit: monobank_account.raw_balance },
                                              source: MonobankEntry::Processor::SOURCE)
      end
    end

    def set_opening_anchor(account)
      return unless monobank_account.history_complete? && monobank_account.opening_anchor_set_at.nil?
      return if account.respond_to?(:provider_cutover_date) && account.provider_cutover_date.present?

      oldest = oldest_entry(account)
      balance = oldest ? balance_before(account, oldest) : monobank_account.balance_for(account.accountable_type)
      return if balance.nil?

      result = account.set_opening_anchor_balance(balance: balance)
      monobank_account.update!(opening_anchor_set_at: Time.current) if result.success?
    end

    # The earliest monobank row booked on the account (by monobank time)
    def oldest_entry(account)
      account.entries
             .where(source: MonobankEntry::Processor::SOURCE, entryable_type: "Transaction")
             .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
             .where("transactions.extra -> 'monobank' ->> 'balance_after' IS NOT NULL")
             .order(:date, Arel.sql("(transactions.extra -> 'monobank' ->> 'time')::bigint NULLS LAST"))
             .first
    end

    # Raw balance before the row = balance after it + the money that went out (Sure sign)
    def balance_before(account, entry)
      after = BigDecimal(entry.entryable.extra.dig("monobank", "balance_after").to_s)
      raw_before = after + entry.amount
      limit = monobank_account.credit_limit.to_d
      account.accountable_type == "CreditCard" ? limit - raw_before : raw_before - limit
    rescue ArgumentError
      nil
    end
end
