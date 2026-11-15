class Balance::Materializer
  # Upsert in chunks, so one statement never carries a multi-year history
  PERSIST_BATCH_SIZE = 2_000

  # The columns persisted from each calculated balance. Read by name, so both a
  # Balance::BalanceData and a Balance record work.
  PERSISTED_COLUMNS = %w[
    date balance cash_balance currency
    start_cash_balance start_non_cash_balance
    cash_inflows cash_outflows
    non_cash_inflows non_cash_outflows
    net_market_flows
    cash_adjustments non_cash_adjustments
    flows_factor
  ].freeze

  attr_reader :account, :strategy

  def initialize(account, strategy:)
    @account = account
    @strategy = strategy
  end

  def materialize_balances
    Balance.transaction do
      materialize_holdings
      calculate_balances

      Rails.logger.info("Persisting #{@balances.size} balances")
      persist_balances

      purge_stale_balances

      if strategy == :forward
        update_account_info
      end
    end
  end

  private
    def materialize_holdings
      @holdings = Holding::Materializer.new(account, strategy: strategy).materialize_holdings
    end

    def update_account_info
      # Query fresh balance from DB to get generated column values. The header shows today's
      # balance: future-dated entries extend the history past today but must not count yet.
      account_balances = account.balances.where(currency: account.currency)
      current_balance = account_balances.where("date <= ?", Date.current).order(date: :desc).first ||
                        account_balances.order(date: :asc).first

      if current_balance
        calculated_balance = current_balance.end_balance
        calculated_cash_balance = current_balance.end_cash_balance
      else
        # Fallback if no balance exists
        calculated_balance = 0
        calculated_cash_balance = 0
      end

      Rails.logger.info("Balance update: cash=#{calculated_cash_balance}, total=#{calculated_balance}")

      account.update!(
        balance: calculated_balance,
        cash_balance: calculated_cash_balance
      )
    end

    def calculate_balances
      @balances = calculator.calculate
      # One debug log entry for the entries left out and holdings kept at 1:1 for want of
      # an exchange rate
      calculator.report_unconverted_amounts
    end

    def persist_balances
      current_time = Time.now

      @balances.each_slice(PERSIST_BATCH_SIZE) do |slice|
        account.balances.upsert_all(
          slice.map { |b| PERSISTED_COLUMNS.to_h { |column| [ column, b.public_send(column) ] }.merge("updated_at" => current_time) },
          unique_by: %i[account_id date currency]
        )
      end
    end

    def purge_stale_balances
      # Nothing was calculated, so every stored row is stale (a `date < NULL` purge would keep them all)
      if @balances.empty?
        deleted_count = account.balances.delete_all
        Rails.logger.info("Purged #{deleted_count} stale balances") if deleted_count > 0
        return
      end

      oldest_balance, newest_balance = @balances.minmax_by(&:date)
      oldest_calculated_balance_date = oldest_balance.date
      newest_calculated_balance_date = newest_balance.date
      deleted_count = account.balances.delete_by("date < ? OR date > ?", oldest_calculated_balance_date, newest_calculated_balance_date)
      Rails.logger.info("Purged #{deleted_count} stale balances") if deleted_count > 0
    end

    # Memoized, so the unconverted-amounts report reads the cache the calculation built
    def calculator
      @calculator ||= if strategy == :reverse
        Balance::ReverseCalculator.new(account)
      else
        Balance::ForwardCalculator.new(account)
      end
    end
end
