# One calculated daily holding, as the holding calculators and Holding.gapfill return it.
# A plain Struct rather than a Holding record, for the same reason as
# Balance::BalanceData: Holding::Materializer writes the rows with upsert_all.
Holding::HoldingData = Struct.new(
  :account_id, :security_id, :date,
  :qty, :price, :currency, :amount, :cost_basis,
  keyword_init: true
) do
  # For callers outside the sync path (tests, the console). The sync path reads only the
  # ids, so these never query during a sync.
  def security
    return @security if defined?(@security)

    @security = security_id && Security.find_by(id: security_id)
  end

  def account
    return @account if defined?(@account)

    @account = account_id && Account.find_by(id: account_id)
  end
end
