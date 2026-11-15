class Account::Syncer
  attr_reader :account

  def initialize(account)
    @account = account
  end

  def perform_sync(sync)
    strategy = account.balance_strategy
    Rails.logger.info("Processing balances (#{strategy})")
    import_market_data
    # Manual balances run forward from the opening anchor; keep it before every entry. So
    # does the hand-kept part of a cutover account (before its cutover date). Linked
    # accounts run backward from the provider's current balance instead.
    account.move_opening_anchor_before_oldest_entry! if strategy.in?(%i[forward cutover]) && (account.manual? || account.provider_cutover_date)
    materialize_balances(strategy)
  end

  # Only the pairs with a leg in this account: the family sync matches the rest
  def perform_post_sync
    account.family.auto_match_transfers!(account: account)
  end

  private
    def materialize_balances(strategy)
      Balance::Materializer.new(account, strategy: strategy).materialize_balances
    end

    # Syncs all the exchange rates + security prices this account needs to display historical chart data
    #
    # This is a *supplemental* sync.  The daily market data sync should have already populated
    # a majority or all of this data, so this is often a no-op.
    #
    # We rescue errors here because if this operation fails, we don't want to fail the entire sync since
    # we have reasonable fallbacks for missing market data.
    def import_market_data
      Account::MarketDataImporter.new(account).import_all
    rescue => e
      Rails.logger.error("Error syncing market data for account #{account.id}: #{e.message}")
      Sentry.capture_exception(e)
    end
end
