# One calculated daily balance, as the balance calculators return it. A plain Struct
# rather than a Balance record: the materializer writes the rows with upsert_all, so the
# record's attribute sets, dirty tracking, type casting and callbacks were allocated for
# every day of every account's history and never used.
Balance::BalanceData = Struct.new(
  :account, :date, :currency, :balance, :cash_balance,
  :start_cash_balance, :start_non_cash_balance,
  :cash_inflows, :cash_outflows,
  :non_cash_inflows, :non_cash_outflows,
  :cash_adjustments, :non_cash_adjustments,
  :net_market_flows, :flows_factor,
  keyword_init: true
) do
  def account_id
    account&.id
  end
end
