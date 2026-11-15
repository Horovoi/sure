# "Materializes" holdings (similar to a DB materialized view, but done at the app level)
# into a series of records we can easily query and join with other data.
class Holding::Materializer
  # Upsert in chunks, so one statement never carries a multi-year history
  PERSIST_BATCH_SIZE = 2_000

  def initialize(account, strategy:)
    @account = account
    @strategy = strategy
  end

  def materialize_holdings
    calculate_holdings

    Rails.logger.info("Persisting #{@holdings.size} holdings")
    persist_holdings

    if strategy == :forward
      purge_stale_holdings
    end

    # Clean up calculated holdings for securities that now have provider-sourced holdings
    # This prevents duplicates when a manually-entered account gets linked to a provider
    cleanup_calculated_holdings_for_provider_securities

    # Clear the holdings association cache so the next reader (Balance::SyncCache) sees
    # the fresh rows. reset, not reload: the reader plucks what it needs, so loading every
    # holding record here was wasted.
    account.holdings.reset

    @holdings
  end

  private
    attr_reader :account, :strategy

    def calculate_holdings
      @holdings = calculator.calculate
    end

    def persist_holdings
      return if @holdings.empty?

      current_time = Time.now

      # Load existing holdings to check locked status and source priority
      existing_holdings_map = load_existing_holdings_map

      # Separate holdings into categories based on cost_basis reconciliation
      holdings_to_upsert_with_cost = []
      holdings_to_upsert_without_cost = []
      holdings_to_upsert_with_manual_cost = []

      @holdings.each do |holding|
        # Skip securities that have provider-sourced holdings - don't overwrite provider data
        next if provider_sourced_security_ids.include?(holding.security_id)

        key = holding_key(holding)
        existing = existing_holdings_map[key]

        # Skip provider-sourced holdings - they have authoritative data from the provider
        # (e.g., Coinbase) and should not be overwritten by calculated holdings
        if existing&.account_provider_id.present?
          Rails.logger.debug(
            "Holding::Materializer - Skipping provider-sourced holding id=#{existing.id} " \
            "security_id=#{existing.security_id} date=#{existing.date}"
          )
          next
        end

        reconciled = Holding::CostBasisReconciler.reconcile(
          existing_holding: existing,
          incoming_cost_basis: holding.cost_basis,
          incoming_source: "calculated"
        )

        # Read field by field: a calculated holding is a Holding::HoldingData, not a record
        base_attrs = {
          "date" => holding.date,
          "currency" => holding.currency,
          "qty" => holding.qty,
          "price" => holding.price,
          "amount" => holding.amount,
          "security_id" => holding.security_id,
          "account_id" => account.id,
          "updated_at" => current_time
        }

        manual = manual_cost_basis_for(holding)

        if existing&.cost_basis_locked?
          # For locked holdings, preserve ALL cost_basis fields
          holdings_to_upsert_without_cost << base_attrs
        elsif manual
          # A manual cost basis belongs to the position, not to the day it was entered:
          # carry it forward to the later rows the calculator builds (one per day).
          holdings_to_upsert_with_manual_cost << base_attrs.merge(
            "cost_basis" => manual.cost_basis,
            "cost_basis_source" => "manual",
            "cost_basis_locked" => true
          )
        elsif holding.cost_basis_unknown && clearable_calculated_basis?(existing)
          # No cost basis can be known for this position now (it holds transferred-in
          # units, or a held purchase has no exchange rate). A nil from the calculator
          # alone would leave the earlier calculated figure standing, which reports a
          # transferred coin as bought on the day it arrived. Cleared, so the read path
          # answers "unknown". A manual or provider figure is somebody's statement of
          # what the position cost, and stays (handled above or not clearable).
          holdings_to_upsert_with_cost << base_attrs.merge(
            "cost_basis" => nil,
            "cost_basis_source" => nil
          )
        elsif reconciled[:should_update] && reconciled[:cost_basis].present?
          # Update with new cost_basis and source
          holdings_to_upsert_with_cost << base_attrs.merge(
            "cost_basis" => reconciled[:cost_basis],
            "cost_basis_source" => reconciled[:cost_basis_source]
          )
        else
          # No cost_basis to set, or existing is better - don't touch cost_basis fields
          holdings_to_upsert_without_cost << base_attrs
        end
      end

      # With cost_basis updates, with the carried manual cost basis, then without
      # cost_basis (preserves the existing value)
      upsert_in_batches(holdings_to_upsert_with_cost)
      upsert_in_batches(holdings_to_upsert_with_manual_cost)
      upsert_in_batches(holdings_to_upsert_without_cost)
    end

    def upsert_in_batches(rows)
      rows.each_slice(PERSIST_BATCH_SIZE) do |slice|
        account.holdings.upsert_all(slice, unique_by: %i[account_id security_id date currency])
      end
    end

    # The latest locked manual cost basis on or before the holding's date, for the same
    # security and currency.
    def manual_cost_basis_for(holding)
      manual_cost_bases[[ holding.security_id, holding.currency ]]&.reverse_each&.find { |locked| locked.date <= holding.date }
    end

    def manual_cost_bases
      @manual_cost_bases ||= account.holdings
        .where(cost_basis_locked: true, cost_basis_source: "manual")
        .where.not(cost_basis: nil)
        .order(:date)
        .group_by { |h| [ h.security_id, h.currency ] }
    end

    # A figure this app worked out (or one with no recorded source), as opposed to one
    # somebody asserted. Nothing to clear when there is no figure.
    def clearable_calculated_basis?(existing)
      return false if existing.nil? || existing.cost_basis.nil? || existing.cost_basis_locked?

      existing.cost_basis_source.nil? || existing.cost_basis_source == "calculated"
    end

    def load_existing_holdings_map
      # Load holdings that might affect reconciliation:
      # - Locked holdings (must preserve their cost_basis)
      # - Holdings with a source (need to check priority)
      # - Provider-sourced holdings (must not be overwritten)
      # - Anything carrying a cost_basis, source or not: otherwise a figure with no
      #   source is invisible here and the unknown-basis clearing leaves it standing
      account.holdings
        .where(cost_basis_locked: true)
        .or(account.holdings.where.not(cost_basis_source: nil))
        .or(account.holdings.where.not(account_provider_id: nil))
        .or(account.holdings.where.not(cost_basis: nil))
        .index_by { |h| holding_key(h) }
    end

    # Get security IDs that have provider-sourced holdings (any date)
    # These should be preserved and not overwritten by calculated holdings
    def provider_sourced_security_ids
      @provider_sourced_security_ids ||= account.holdings
        .where.not(account_provider_id: nil)
        .distinct
        .pluck(:security_id)
    end

    # Remove calculated holdings (account_provider_id IS NULL) for securities
    # that now have provider-sourced holdings. This prevents duplicates when
    # a manually-entered account gets linked to a provider.
    def cleanup_calculated_holdings_for_provider_securities
      return if provider_sourced_security_ids.empty?

      deleted_count = account.holdings
        .where(account_provider_id: nil)
        .where(security_id: provider_sourced_security_ids)
        .delete_all

      Rails.logger.info("Cleaned up #{deleted_count} calculated holdings for provider-sourced securities") if deleted_count > 0
    end

    def holding_key(holding)
      [ holding.account_id || account.id, holding.security_id, holding.date, holding.currency ]
    end

    def purge_stale_holdings
      # One query for the distinct securities, rather than loading every trade to read its security
      portfolio_security_ids = account.trades.distinct.pluck(:security_id)

      # Never delete provider-sourced holdings - they're authoritative from the provider
      # If there are no securities in the portfolio, only delete non-provider holdings
      if portfolio_security_ids.empty?
        Rails.logger.info("Clearing non-provider holdings (no securities from trades)")
        account.holdings.where(account_provider_id: nil).delete_all
      else
        # Keep provider holdings and holdings for known securities within date range
        deleted_count = account.holdings
          .where(account_provider_id: nil)
          .delete_by("date < ? OR security_id NOT IN (?)", account.start_date, portfolio_security_ids)
        Rails.logger.info("Purged #{deleted_count} stale holdings") if deleted_count > 0
      end
    end

    def calculator
      if strategy == :reverse
        portfolio_snapshot = Holding::PortfolioSnapshot.new(account)
        Holding::ReverseCalculator.new(account, portfolio_snapshot: portfolio_snapshot)
      else
        Holding::ForwardCalculator.new(account)
      end
    end
end
