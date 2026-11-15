class BalanceSheet::AccountTotals
  def initialize(family, sync_status_monitor:)
    @family = family
    @sync_status_monitor = sync_status_monitor
  end

  def asset_accounts
    @asset_accounts ||= account_rows.filter { |t| t.classification == "asset" }
  end

  def liability_accounts
    @liability_accounts ||= account_rows.filter { |t| t.classification == "liability" }
  end

  private
    attr_reader :family, :sync_status_monitor

    AccountRow = Data.define(:account, :converted_balance, :is_syncing) do
      def syncing? = is_syncing

      # Allows Rails path helpers to generate URLs from the wrapper
      def to_param = account.to_param
      delegate_missing_to :account
    end

    def visible_accounts
      @visible_accounts ||= family.accounts.visible.with_attached_logo
    end

    # Draft accounts, and accounts excluded from reports (w3-reports), are listed with
    # their own balance but count as zero in every total and weight.
    def account_rows
      @account_rows ||= accounts_with_display_associations.map do |account_row|
        counted = account_row.counted_in_totals? && account_row.included_in_reports?

        AccountRow.new(
          account: account_row,
          converted_balance: counted ? account_row.converted_balance : 0,
          is_syncing: sync_status_monitor.account_syncing?(account_row)
        )
      end
    end

    # The sidebar and balance sheet read each account's subtype (from its accountable)
    # and its provider links. Load them for all accounts at once, instead of one
    # lookup per account while rendering. Done after the cache read, so these
    # records are always fresh and never stored in the cache.
    def accounts_with_display_associations
      accounts = query

      ActiveRecord::Associations::Preloader.new(
        records: accounts,
        associations: [ :accountable, { account_providers: :provider } ]
      ).call

      accounts
    end

    def cache_key
      family.build_cache_key(
        "balance_sheet_account_rows",
        invalidate_on_data_updates: true
      )
    end

    def query
      @query ||= Rails.cache.fetch(cache_key, expires_in: Family::AGGREGATE_CACHE_TTL) do
        # Today's balance at the nearest stored rate (not only an exact rate for today). An
        # account in a currency with no rate at all converts to 0, so it is left out of every
        # total rather than counted at 1; its row still shows its own balance, and the page
        # says the currency is missing (shared/_exchange_rate_notes).
        rate = ExchangeRate.rate_sql(
          from: "accounts.currency",
          to: ActiveRecord::Base.connection.quote(family.currency),
          on: ActiveRecord::Base.connection.quote(Date.current)
        )

        visible_accounts
          .select(
            "accounts.*",
            "COALESCE(SUM(accounts.balance * #{rate}), 0) as converted_balance"
          )
          .group(:classification, :accountable_type, :id)
          .to_a
      end
    end
end
