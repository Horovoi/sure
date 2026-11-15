class Account::ProviderImportAdapter
  attr_reader :account, :skipped_entries, :claimed_entries

  def initialize(account)
    @account = account
    @skipped_entries = []
    @claimed_entries = []
  end

  # Resets skipped entries tracking (call at start of new sync batch)
  def reset_skipped_entries!
    @skipped_entries = []
    @claimed_entries = []
  end

  # Imports a transaction from a provider
  #
  # @param external_id [String] Unique identifier from the provider (e.g., "plaid_12345", "lunchflow_abc")
  # @param amount [BigDecimal, Numeric] Transaction amount
  # @param currency [String] Currency code (e.g., "USD")
  # @param date [Date, String] Transaction date
  # @param name [String] Transaction name/description
  # @param source [String] Provider name (e.g., "plaid", "lunchflow")
  # @param category_id [Integer, nil] Optional category ID
  # @param merchant [Merchant, nil] Optional merchant object
  # @param notes [String, nil] Optional transaction notes/memo
  # @param pending_transaction_id [String, nil] Plaid's linking ID for pending→posted reconciliation
  # @param extra [Hash, nil] Optional provider-specific metadata to merge into transaction.extra
  # @param investment_activity_label [String, nil] Optional activity type label (e.g., "Buy", "Dividend")
  # @param claimed_entry [Entry, nil, :auto] The existing entry this row matches (from an
  #   Account::ProviderEntryClaimer batch), nil for none, or :auto to look one up here
  #   (Account::ProviderEntryClaimer#match_one). A new posted row takes that entry over. A
  #   new pending row is not booked while it matches one (the entry already records the
  #   purchase; the settled row claims it). A hold this provider booked earlier that
  #   settles while it matches one is replaced by it.
  # @param category_id_if_blank [String, nil] Category set only while the transaction has
  #   none (a guess such as the MCC category, which rules and the user may change). Never
  #   on a transfer leg. Recorded as extra[source]["guessed_category_id"].
  # @param cutover_date [Date, nil] The account's provider cutover date: a new row dated
  #   before it that claims nothing is not imported (returns nil, skip "before_cutover")
  # @param holds_keep_id [Boolean] The provider settles a hold under the hold's own id
  #   (monobank), so a new posted row is never the settlement of a pending entry: the
  #   pending-to-posted matching and the duplicate suggestions are skipped.
  # @param refresh_details [Boolean] Whether a row already booked gets its name, merchant
  #   and category written again. A provider that sends every stored row on each pass
  #   (monobank) passes false, so merchant conversions, merges and rule-set names stay;
  #   a hold that settles is still written.
  # @return [Entry, nil] The created, updated or claimed entry; nil when not booked
  def import_transaction(external_id:, amount:, currency:, date:, name:, source:, category_id: nil, merchant: nil, notes: nil, pending_transaction_id: nil, extra: nil, investment_activity_label: nil, claimed_entry: :auto, category_id_if_blank: nil, cutover_date: nil, holds_keep_id: false, refresh_details: true)
    raise ArgumentError, "external_id is required" if external_id.blank?
    raise ArgumentError, "source is required" if source.blank?

    Account.transaction do
      # Find by both external_id AND source
      # This allows multiple providers to sync same account with separate entries.
      # A new entry is only built once nothing else (a claim, the cutover) handles the row:
      # a built entry left on account.entries would be autosaved by a later account save.
      entry = account.entries.find_by(external_id: external_id, source: source) ||
        Entry.new(account: account, external_id: external_id, source: source, entryable: Transaction.new)

      # === TYPE COLLISION CHECK: Must happen before protection check ===
      # If entry exists but is a different type (e.g., Trade), that's an error.
      # This prevents external_id collisions across different entryable types.
      if entry.persisted? && !entry.entryable.is_a?(Transaction)
        raise ArgumentError, "Entry with external_id '#{external_id}' already exists with different entryable type: #{entry.entryable_type}"
      end

      incoming_pending = pending_extra?(extra)
      # A hold this provider booked that now arrives settled under the same id
      settling = entry.persisted? && !incoming_pending && provider_pending?(entry, source)

      # The hold was booked next to a hand-entered entry of the same purchase: the
      # settled row takes that entry over and the hold goes, unless the user attached
      # something to it (Account::ProviderPendingPruner#protected?)
      if settling && !Account::ProviderPendingPruner.new(account, source: source).protected?(entry)
        claim = resolve_claim(claimed_entry, key: external_id, date: date, amount: amount, currency: currency, source: source)
        if claim
          entry.destroy!
          return claim_entry!(claim, external_id: external_id, source: source, extra: extra, category_id_if_blank: category_id_if_blank)
        end
      end

      # === PROTECTION CHECK: Skip entries that should not be overwritten ===
      # Check persisted Transaction entries for protection flags before making changes.
      # This prevents sync from overwriting user edits, CSV imports, excluded entries,
      # and entries the provider took over from the user's own history. A hold the user
      # edited still gets the bank's settled amount, date and pending flag.
      if entry.persisted?
        skip_reason = determine_skip_reason(entry)
        if skip_reason
          return settle_protected_hold!(entry, amount: amount, currency: currency, date: date, extra: extra) if settling && skip_reason.in?(%w[user_modified excluded])

          record_skip(entry, skip_reason)
          return entry
        end
      end

      # A new posted row may already be recorded by a manual or imported entry (same
      # signed amount, up to 3 days apart; see Account::ProviderEntryClaimer). The
      # provider takes that entry over and keeps what the user recorded. A new hold that
      # matches one is not booked: the entry stays the record until the hold settles.
      # Generated subscription charges are left to RecurringTransaction::Reconciler.
      # (holds only in a batch: claimed_entry given as an Entry)
      if entry.new_record? && (!incoming_pending || claimed_entry.is_a?(Entry))
        claim = resolve_claim(claimed_entry, key: external_id, date: date, amount: amount, currency: currency, source: source, pending: incoming_pending)
        if claim && incoming_pending
          record_skip(claim, "pending_matches_entry", external_id: external_id)
          return nil
        elsif claim
          return claim_entry!(claim, external_id: external_id, source: source, extra: extra, category_id_if_blank: category_id_if_blank)
        end
      end

      # Rows dated before the cutover belong to the history the user kept by hand
      if entry.new_record? && cutover_date && parse_date(date) < cutover_date.to_date
        record_skip(nil, "before_cutover", external_id: external_id, date: parse_date(date))
        return nil
      end

      # If still a new entry and this is a POSTED transaction, check for matching pending transactions
      if entry.new_record? && !incoming_pending && !holds_keep_id
        pending_match = nil

        # PRIORITY 1: Use Plaid's pending_transaction_id if provided (most reliable)
        # Plaid explicitly links pending→posted with this ID - no guessing required
        if pending_transaction_id.present?
          pending_match = account.entries.find_by(external_id: pending_transaction_id, source: source)
          if pending_match
            Rails.logger.info("Reconciling pending→posted via Plaid pending_transaction_id: claiming entry #{pending_match.id} (#{pending_match.name}) with new external_id #{external_id}")
          end
        end

        # PRIORITY 2: Fallback to EXACT amount match (for providers without linking IDs)
        # Only searches backward in time - pending date must be <= posted date
        if pending_match.nil?
          pending_match = find_pending_transaction(date: date, amount: amount, currency: currency, source: source)
          if pending_match
            Rails.logger.info("Reconciling pending→posted via exact amount match: claiming entry #{pending_match.id} (#{pending_match.name}) with new external_id #{external_id}")
          end
        end

        if pending_match
          entry = pending_match
          entry.assign_attributes(external_id: external_id)
        end
      end

      # Track if this is a new posted transaction (for fuzzy suggestion after save)
      is_new_posted = entry.new_record? && !incoming_pending && !holds_keep_id
      write_details = entry.new_record? || refresh_details || settling

      entry.assign_attributes(
        amount: amount,
        currency: currency,
        date: date
      )

      # Use enrichment pattern to respect user overrides
      entry.enrich_attribute(:name, name, source: source) if write_details

      # Enrich transaction-specific attributes
      guessed_category_id = nil
      if category_id
        entry.transaction.enrich_attribute(:category_id, category_id, source: source) if write_details
      elsif category_id_if_blank && write_details && entry.transaction.category_id.blank? && !transfer_leg?(entry)
        entry.transaction.enrich_attribute(:category_id, category_id_if_blank, source: source, metadata: { via: "mcc" })
        guessed_category_id = entry.transaction.category_id if entry.transaction.category_id.to_s == category_id_if_blank.to_s
      end

      if merchant && write_details
        entry.transaction.enrich_attribute(:merchant_id, merchant.id, source: source)
      end

      if notes.present? && entry.respond_to?(:enrich_attribute)
        entry.enrich_attribute(:notes, notes, source: source)
      end

      # Persist extra provider metadata on the transaction (non-enriched; always merged)
      if extra.present? && entry.entryable.is_a?(Transaction)
        existing = entry.transaction.extra || {}
        incoming = extra.is_a?(Hash) ? extra.deep_stringify_keys : {}
        entry.transaction.extra = existing.deep_merge(incoming)
        entry.transaction.save!
      end

      note_category_guess(entry.transaction, source, guessed_category_id) if guessed_category_id

      # Auto-detect investment activity labels for investment accounts
      detected_label = investment_activity_label
      if account.investment? && detected_label.nil? && entry.entryable.is_a?(Transaction)
        detected_label = detect_activity_label(name, amount)
      end

      # Auto-set kind for internal movements and contributions
      auto_kind = nil
      auto_category = nil
      if Transaction::INTERNAL_MOVEMENT_LABELS.include?(detected_label)
        auto_kind = "funds_movement"
      elsif detected_label == "Contribution"
        auto_kind = "investment_contribution"
        auto_category = account.family.investment_contributions_category
      end

      # Set investment activity label, kind, and category if detected
      if entry.entryable.is_a?(Transaction)
        if detected_label.present? && entry.transaction.investment_activity_label.blank?
          entry.transaction.assign_attributes(investment_activity_label: detected_label)
        end

        # Transfer is the only writer of a transfer leg's kind
        if auto_kind.present? && !transfer_leg?(entry)
          entry.transaction.assign_attributes(kind: auto_kind)
        end

        if auto_category.present? && entry.transaction.category_id.blank?
          entry.transaction.assign_attributes(category: auto_category)
        end
      end

      entry.save!
      entry.transaction.save! if entry.transaction.changed?

      # AFTER save: For NEW posted transactions, check for fuzzy matches to SUGGEST (not auto-claim)
      # This handles tip adjustments where auto-matching is too risky
      if is_new_posted
        # PRIORITY 1: Try medium-confidence fuzzy match (≤30% amount difference)
        fuzzy_suggestion = find_pending_transaction_fuzzy(
          date: date,
          amount: amount,
          currency: currency,
          source: source,
          merchant_id: merchant&.id,
          name: name
        )
        if fuzzy_suggestion
          # Store suggestion on the PENDING entry for user to review
          begin
            fuzzy_suggestion.entryable.flag_potential_duplicate!(
              posted_entry: entry,
              reason: "fuzzy_amount_match",
              posted_amount: amount,
              confidence: "medium"
            )
            Rails.logger.info("Suggested potential duplicate (medium confidence): pending entry #{fuzzy_suggestion.id} (#{fuzzy_suggestion.name}, #{fuzzy_suggestion.amount}) may match posted #{entry.name} (#{amount})")
          rescue ActiveRecord::RecordInvalid => e
            Rails.logger.warn("Failed to store duplicate suggestion for entry #{fuzzy_suggestion.id}: #{e.message}")
          end
        else
          # PRIORITY 2: Try low-confidence match (>30% to 100% difference - big tips)
          low_confidence_suggestion = find_pending_transaction_low_confidence(
            date: date,
            amount: amount,
            currency: currency,
            source: source,
            merchant_id: merchant&.id,
            name: name
          )
          if low_confidence_suggestion
            begin
              low_confidence_suggestion.entryable.flag_potential_duplicate!(
                posted_entry: entry,
                reason: "low_confidence_match",
                posted_amount: amount,
                confidence: "low"
              )
              Rails.logger.info("Suggested potential duplicate (low confidence): pending entry #{low_confidence_suggestion.id} (#{low_confidence_suggestion.name}, #{low_confidence_suggestion.amount}) may match posted #{entry.name} (#{amount})")
            rescue ActiveRecord::RecordInvalid => e
              Rails.logger.warn("Failed to store duplicate suggestion for entry #{low_confidence_suggestion.id}: #{e.message}")
            end
          end
        end
      end

      entry
    end
  end

  # Finds or creates a merchant from provider data
  #
  # @param provider_merchant_id [String] Provider's merchant ID
  # @param name [String] Merchant name
  # @param source [String] Provider name (e.g., "plaid", "lunchflow")
  # @param website_url [String, nil] Optional merchant website
  # @param logo_url [String, nil] Optional merchant logo URL
  # @return [ProviderMerchant, nil] The merchant object or nil if data is insufficient
  def find_or_create_merchant(provider_merchant_id:, name:, source:, website_url: nil, logo_url: nil)
    return nil unless provider_merchant_id.present? && name.present?

    # First try to find by provider_merchant_id (stable identifier derived from normalized name)
    # This handles case variations in merchant names (e.g., "ACME Corp" vs "Acme Corp")
    merchant = ProviderMerchant.find_by(provider_merchant_id: provider_merchant_id, source: source)

    # If not found by provider_merchant_id, try by exact name match (backwards compatibility)
    merchant ||= ProviderMerchant.find_by(source: source, name: name)

    if merchant
      # Update logo if provided and merchant doesn't have one (or has a different one)
      # Best-effort: don't fail transaction import if logo update fails
      if logo_url.present? && merchant.logo_url != logo_url
        begin
          merchant.update!(logo_url: logo_url)
        rescue StandardError => e
          Rails.logger.warn("Failed to update merchant logo: merchant_id=#{merchant.id} logo_url=#{logo_url} error=#{e.message}")
        end
      end
      return merchant
    end

    # Create new merchant
    begin
      merchant = ProviderMerchant.create!(
        source: source,
        name: name,
        provider_merchant_id: provider_merchant_id,
        website_url: website_url,
        logo_url: logo_url
      )
    rescue ActiveRecord::RecordNotUnique
      # Race condition - another process created the record
      merchant = ProviderMerchant.find_by(provider_merchant_id: provider_merchant_id, source: source) ||
                 ProviderMerchant.find_by(source: source, name: name)
    end

    merchant
  end

  # Updates account balance from provider data
  #
  # @param balance [BigDecimal, Numeric] Total balance
  # @param cash_balance [BigDecimal, Numeric] Cash balance (for investment accounts)
  # @param source [String] Provider name (for logging/debugging)
  #
  # The balance is written as the account's current anchor (Account::CurrentBalanceManager),
  # which the reverse and cutover balance calculations start from, and as accounts.balance.
  # Does not enqueue a sync: the provider's item sync syncs its accounts afterwards.
  #
  # @return [Account::CurrentBalanceManager::Result]
  def update_balance(balance:, cash_balance: nil, source: nil)
    make_room_for_current_anchor!(source) if account.linked?
    result = Account::CurrentBalanceManager.new(account).set_current_balance(balance)

    if result.success?
      account.update_columns(cash_balance: cash_balance || balance, updated_at: Time.current)
    else
      Rails.logger.error("Failed to update balance of account #{account.id} from #{source}: #{result.error}")
    end

    result
  end

  # Imports or updates a holding (investment position) from a provider
  #
  # @param security [Security] The security object
  # @param quantity [BigDecimal, Numeric] Number of shares/units
  # @param amount [BigDecimal, Numeric] Total value in account currency
  # @param currency [String] Currency code
  # @param date [Date, String] Holding date
  # @param price [BigDecimal, Numeric, nil] Price per share (optional)
  # @param cost_basis [BigDecimal, Numeric, nil] Cost basis (optional)
  # @param external_id [String, nil] Provider's unique ID (optional, for deduplication)
  # @param source [String] Provider name
  # @param account_provider_id [String, nil] The AccountProvider ID that owns this holding (optional)
  # @param delete_future_holdings [Boolean] Whether to delete holdings after this date (default: false)
  # @return [Holding] The created or updated holding
  def import_holding(security:, quantity:, amount:, currency:, date:, price: nil, cost_basis: nil, external_id: nil, source:, account_provider_id: nil, delete_future_holdings: false)
    raise ArgumentError, "security is required" if security.nil?
    raise ArgumentError, "source is required" if source.blank?

    Account.transaction do
      # Two strategies for finding/creating holdings:
      # 1. By external_id - tracks each holding uniquely
      # 2. By security+date+currency (Plaid approach) - overwrites holdings for same security/date
      holding = nil

      if external_id.present?
        # Preferred path: match by provider's external_id
        holding = account.holdings.find_by(external_id: external_id)

        unless holding
          # Fallback path: match by (security, date, currency) — and when provided,
          # also scope by account_provider_id to avoid cross‑provider claiming.
          # This keeps behavior symmetric with deletion logic below which filters
          # by account_provider_id when present.
          find_by_attrs = {
            security: security,
            date: date,
            currency: currency
          }
          if account_provider_id.present?
            find_by_attrs[:account_provider_id] = account_provider_id
          end

          holding = account.holdings.find_by(find_by_attrs)
        end

        holding ||= account.holdings.new(
          security: security,
          date: date,
          currency: currency,
          account_provider_id: account_provider_id
        )
      else
        holding = account.holdings.find_or_initialize_by(
          security: security,
          date: date,
          currency: currency
        )
      end

      # Early cross-provider composite-key conflict guard: avoid attempting a write
      # that would violate a unique index on (account_id, security_id, date, currency).
      if external_id.present?
        existing_composite = account.holdings.find_by(
          security: security,
          date: date,
          currency: currency
        )

        if existing_composite &&
           account_provider_id.present? &&
           existing_composite.account_provider_id.present? &&
           existing_composite.account_provider_id != account_provider_id
          Rails.logger.warn(
            "ProviderImportAdapter: cross-provider holding collision for account=#{account.id} security=#{security.id} date=#{date} currency=#{currency}; returning existing id=#{existing_composite.id}"
          )
          return existing_composite
        end
      end

      # Reconcile cost_basis to respect priority hierarchy
      reconciled = Holding::CostBasisReconciler.reconcile(
        existing_holding: holding.persisted? ? holding : nil,
        incoming_cost_basis: cost_basis,
        incoming_source: "provider"
      )

      # Build base attributes
      attributes = {
        security: security,
        date: date,
        currency: currency,
        qty: quantity,
        price: price,
        amount: amount,
        account_provider_id: account_provider_id,
        external_id: external_id
      }

      # Only update cost_basis if reconciliation says to
      if reconciled[:should_update]
        attributes[:cost_basis] = reconciled[:cost_basis]
        attributes[:cost_basis_source] = reconciled[:cost_basis_source]
      end

      holding.assign_attributes(attributes)

      begin
        Holding.transaction(requires_new: true) do
          holding.save!
        end
      rescue ActiveRecord::RecordNotUnique => e
        # Handle unique index collisions on (account_id, security_id, date, currency)
        # that can occur when another provider (or concurrent import) already
        # created a row for this composite key. Use the existing row and keep
        # the outer transaction valid by isolating the error in a savepoint.
        existing = account.holdings.find_by(
          security: security,
          date: date,
          currency: currency
        )

        if existing
          # If an existing row belongs to a different provider, do NOT claim it.
          # Keep cross-provider isolation symmetrical with deletion logic.
          if account_provider_id.present? && existing.account_provider_id.present? && existing.account_provider_id != account_provider_id
            Rails.logger.warn(
              "ProviderImportAdapter: cross-provider holding collision for account=#{account.id} security=#{security.id} date=#{date} currency=#{currency}; returning existing id=#{existing.id}"
            )
            holding = existing
          else
            # Same provider (or unowned). Apply latest snapshot and attach external_id for idempotency.
            updates = {
              qty: quantity,
              price: price,
              amount: amount
            }

            # Reconcile cost_basis to respect priority hierarchy
            collision_reconciled = Holding::CostBasisReconciler.reconcile(
              existing_holding: existing,
              incoming_cost_basis: cost_basis,
              incoming_source: "provider"
            )

            if collision_reconciled[:should_update]
              updates[:cost_basis] = collision_reconciled[:cost_basis]
              updates[:cost_basis_source] = collision_reconciled[:cost_basis_source]
            end

            # Adopt the row to this provider if it's currently unowned
            if account_provider_id.present? && existing.account_provider_id.nil?
              updates[:account_provider_id] = account_provider_id
            end

            # Attach external_id if provided and missing
            if external_id.present? && existing.external_id.blank?
              updates[:external_id] = external_id
            end

            begin
              # Use update_columns to avoid validations and keep this collision handler best-effort.
              existing.update_columns(updates.compact)
            rescue => _
              # Best-effort only; avoid raising in collision handler
            end

            holding = existing
          end
        else
          # Could not find an existing row; re-raise original error
          raise e
        end
      end

      # Optionally delete future holdings for this security (Plaid behavior)
      # Only delete if ALL providers allow deletion (cross-provider check)
      if delete_future_holdings
        unless account.can_delete_holdings?
          Rails.logger.warn(
            "Skipping future holdings deletion for account #{account.id} " \
            "because not all providers allow deletion"
          )
          return holding
        end

        # Build base query for future holdings
        future_holdings_query = account.holdings
          .where(security: security)
          .where("date > ?", date)

        # If account_provider_id is provided, only delete holdings from this provider
        # This prevents deleting positions imported by other providers
        if account_provider_id.present?
          future_holdings_query = future_holdings_query.where(account_provider_id: account_provider_id)
        end

        future_holdings_query.destroy_all
      end

      holding
    end
  end

  # Imports a trade (investment transaction) from a provider
  #
  # @param security [Security] The security object
  # @param quantity [BigDecimal, Numeric] Number of shares (negative for sells, positive for buys)
  # @param price [BigDecimal, Numeric] Price per share
  # @param amount [BigDecimal, Numeric] Total trade value
  # @param currency [String] Currency code
  # @param date [Date, String] Trade date
  # @param name [String, nil] Optional custom name for the trade
  # @param external_id [String, nil] Provider's unique ID (optional, for deduplication)
  # @param source [String] Provider name
  # @param activity_label [String, nil] Investment activity label (e.g., "Buy", "Sell", "Reinvestment")
  # @return [Entry] The created entry with trade
  def import_trade(security:, quantity:, price:, amount:, currency:, date:, name: nil, external_id: nil, source:, activity_label: nil)
    raise ArgumentError, "security is required" if security.nil?
    raise ArgumentError, "source is required" if source.blank?

    Account.transaction do
      # Generate name if not provided
      trade_name = if name.present?
        name
      else
        trade_type = quantity.negative? ? "sell" : "buy"
        Trade.build_name(trade_type, quantity, security.ticker)
      end

      # Use find_or_initialize_by with external_id if provided, otherwise create new
      entry = if external_id.present?
        # Find or initialize by both external_id AND source
        # This allows multiple providers to sync same account with separate entries
        account.entries.find_or_initialize_by(external_id: external_id, source: source) do |e|
          e.entryable = Trade.new
        end
      else
        account.entries.new(
          entryable: Trade.new,
          source: source
        )
      end

      # Validate entryable type matches to prevent external_id collisions
      if entry.persisted? && !entry.entryable.is_a?(Trade)
        raise ArgumentError, "Entry with external_id '#{external_id}' already exists with different entryable type: #{entry.entryable_type}"
      end

      # Always update Trade attributes (works for both new and existing records)
      entry.entryable.assign_attributes(
        security: security,
        qty: quantity,
        price: price,
        currency: currency,
        investment_activity_label: activity_label || (quantity > 0 ? "Buy" : "Sell")
      )

      entry.assign_attributes(
        date: date,
        amount: amount,
        currency: currency,
        name: trade_name
      )

      entry.save!
      entry
    end
  end

  # Updates accountable-specific attributes (e.g., credit card details, loan details)
  #
  # @param attributes [Hash] Hash of attributes to update on the accountable
  # @param source [String] Provider name (for logging/debugging)
  # @return [Boolean] Whether the update was successful
  def update_accountable_attributes(attributes:, source:)
    return false unless account.accountable.present?
    return false if attributes.blank?

    # Filter out nil values and only update attributes that exist on the accountable
    valid_attributes = attributes.compact.select do |key, _|
      account.accountable.respond_to?("#{key}=")
    end

    return false if valid_attributes.empty?

    account.accountable.update!(valid_attributes)
    true
  rescue => e
    Rails.logger.error("Failed to update #{account.accountable_type} attributes from #{source}: #{e.message}")
    false
  end

  # Finds a potential duplicate transaction from manual entry or CSV import
  # Matches on date, amount, currency, and optionally name
  # Only matches transactions without external_id (manual/CSV imported)
  #
  # @param date [Date, String] Transaction date
  # @param amount [BigDecimal, Numeric] Transaction amount
  # @param currency [String] Currency code
  # @param name [String, nil] Optional transaction name for more accurate matching
  # @param exclude_entry_ids [Set, Array, nil] Entry IDs to exclude from the search (e.g., already claimed entries)
  # @return [Entry, nil] The duplicate entry or nil if not found
  def find_duplicate_transaction(date:, amount:, currency:, name: nil, exclude_entry_ids: nil)
    # Convert date to Date object if it's a string
    date = Date.parse(date.to_s) unless date.is_a?(Date)

    # Look for entries on the same account with:
    # 1. Same date
    # 2. Same amount (exact match)
    # 3. Same currency
    # 4. No external_id (manual/CSV imported transactions)
    # 5. Entry type is Transaction (not Trade or Valuation)
    # 6. Optionally same name (if name parameter is provided)
    # 7. Not in the excluded IDs list (if provided)
    query = account.entries
                   .where(entryable_type: "Transaction")
                   .where(date: date)
                   .where(amount: amount)
                   .where(currency: currency)
                   .where(external_id: nil)

    # Add name filter if provided
    query = query.where(name: name) if name.present?

    # Exclude already claimed entries if provided
    query = query.where.not(id: exclude_entry_ids) if exclude_entry_ids.present?

    query.order(created_at: :asc).first
  end

  # Finds a pending transaction that likely matches a newly posted transaction
  # Used to reconcile pending→posted when provider gives different IDs for the same transaction
  #
  # @param date [Date, String] Posted transaction date
  # @param amount [BigDecimal, Numeric] Transaction amount (must match exactly)
  # @param currency [String] Currency code
  # @param source [String] Provider name (e.g., "plaid")
  # @param date_window [Integer] Days to search around the posted date (default: 8)
  # @return [Entry, nil] The pending entry or nil if not found
  def find_pending_transaction(date:, amount:, currency:, source:, date_window: 8)
    date = Date.parse(date.to_s) unless date.is_a?(Date)

    # Look for entries that:
    # 1. Same account (implicit via account.entries)
    # 2. Same source
    # 3. Same amount (exact match - this is the strongest signal)
    # 4. Same currency
    # 5. Date within window (pending can post days later)
    # 6. Is a Transaction (not Trade or Valuation)
    # 7. Has pending=true in transaction.extra["plaid"]["pending"]
    candidates = account.entries
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(source: source)
      .where(amount: amount)
      .where(currency: currency)
      .where(date: (date - date_window.days)..date) # Pending must be ON or BEFORE posted date
      .where(<<~SQL.squish)
        EXISTS (
          SELECT 1 FROM jsonb_each(transactions.extra) AS pd
          WHERE (pd.value ->> 'pending')::boolean = true
        )
      SQL
      .order(date: :desc, created_at: :desc) # Prefer most recent pending transaction

    candidates.first
  end

  # Finds a pending transaction using fuzzy amount matching for tip adjustments
  # Used when exact amount matching fails - handles restaurant tips, adjusted authorizations, etc.
  #
  # IMPORTANT: Only returns a match if there's exactly ONE candidate to avoid false positives
  # with recurring merchant transactions (e.g., gas stations, coffee shops).
  #
  # @param date [Date, String] Posted transaction date
  # @param amount [BigDecimal, Numeric] Posted transaction amount (typically higher due to tip)
  # @param currency [String] Currency code
  # @param source [String] Provider name (e.g., "plaid")
  # @param merchant_id [Integer, nil] Merchant ID for more accurate matching
  # @param name [String, nil] Transaction name for fuzzy name matching
  # @param date_window [Integer] Days to search backward from posted date (default: 3 for fuzzy)
  # @param amount_tolerance [Float] Maximum percentage difference allowed (default: 0.30 = 30%)
  # @return [Entry, nil] The pending entry or nil if not found/ambiguous
  def find_pending_transaction_fuzzy(date:, amount:, currency:, source:, merchant_id: nil, name: nil, date_window: 3, amount_tolerance: 0.30)
    date = Date.parse(date.to_s) unless date.is_a?(Date)
    amount = BigDecimal(amount.to_s)

    # Calculate amount bounds using ABS to handle both positive and negative amounts
    # Posted amount should be >= pending (tips add, not subtract)
    # Allow posted to be up to 30% higher than pending (covers typical tips)
    abs_amount = amount.abs
    min_pending_abs = abs_amount / (1 + amount_tolerance) # If posted is 100, pending could be as low as ~77
    max_pending_abs = abs_amount # Pending should not be higher than posted

    # Build base query for pending transactions
    # CRITICAL: Pending must be ON or BEFORE the posted date (authorization happens first)
    # Use tighter date window (3 days) - tips post quickly, not a week later
    # Use ABS() for amount comparison to handle negative amounts correctly
    candidates = account.entries
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(source: source)
      .where(currency: currency)
      .where(date: (date - date_window.days)..date) # Pending ON or BEFORE posted
      .where("ABS(entries.amount) BETWEEN ? AND ?", min_pending_abs, max_pending_abs)
      .where(<<~SQL.squish)
        EXISTS (
          SELECT 1 FROM jsonb_each(transactions.extra) AS pd
          WHERE (pd.value ->> 'pending')::boolean = true
        )
      SQL

    # If merchant_id is provided, prioritize matching by merchant
    if merchant_id.present?
      merchant_matches = candidates.where("transactions.merchant_id = ?", merchant_id).to_a
      # Only match if exactly ONE candidate to avoid false positives
      return merchant_matches.first if merchant_matches.size == 1
      if merchant_matches.size > 1
        Rails.logger.info("Skipping fuzzy pending match: #{merchant_matches.size} ambiguous merchant candidates for amount=#{amount} date=#{date}")
      end
    end

    # If name is provided, try fuzzy name matching as fallback
    if name.present?
      # Extract first few significant words for comparison
      name_words = name.downcase.gsub(/[^a-z0-9\s]/, "").split.first(3).join(" ")
      if name_words.present?
        name_matches = candidates.select do |c|
          c_name_words = c.name.downcase.gsub(/[^a-z0-9\s]/, "").split.first(3).join(" ")
          name_words == c_name_words
        end
        # Only match if exactly ONE candidate to avoid false positives
        return name_matches.first if name_matches.size == 1
        if name_matches.size > 1
          Rails.logger.info("Skipping fuzzy pending match: #{name_matches.size} ambiguous name candidates for '#{name_words}' amount=#{amount} date=#{date}")
        end
      end
    end

    # No merchant or name match, return nil (too risky to match on amount alone)
    # This prevents false positives when multiple pending transactions exist
    nil
  end

  # Finds a pending transaction with low confidence (>30% to 100% amount difference)
  # Used for large tip scenarios where normal fuzzy matching would miss
  # Creates a "review recommended" suggestion rather than "possible duplicate"
  #
  # @param date [Date, String] Posted transaction date
  # @param amount [BigDecimal, Numeric] Posted transaction amount
  # @param currency [String] Currency code
  # @param source [String] Provider name
  # @param merchant_id [Integer, nil] Merchant ID for matching
  # @param name [String, nil] Transaction name for matching
  # @param date_window [Integer] Days to search backward (default: 3)
  # @return [Entry, nil] The pending entry or nil if not found/ambiguous
  def find_pending_transaction_low_confidence(date:, amount:, currency:, source:, merchant_id: nil, name: nil, date_window: 3)
    date = Date.parse(date.to_s) unless date.is_a?(Date)
    amount = BigDecimal(amount.to_s)

    # Allow up to 100% difference (e.g., $50 pending → $100 posted with huge tip)
    # This is low confidence - requires strong name/merchant match
    # Use ABS to handle both positive and negative amounts correctly
    abs_amount = amount.abs
    min_pending_abs = abs_amount / 2.0 # Posted could be up to 2x pending
    max_pending_abs = abs_amount * 0.77 # Pending must be at least 30% less (to not overlap with fuzzy)

    # Build base query for pending transactions
    # Use ABS() for amount comparison to handle negative amounts correctly
    candidates = account.entries
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(source: source)
      .where(currency: currency)
      .where(date: (date - date_window.days)..date)
      .where("ABS(entries.amount) BETWEEN ? AND ?", min_pending_abs, max_pending_abs)
      .where(<<~SQL.squish)
        EXISTS (
          SELECT 1 FROM jsonb_each(transactions.extra) AS pd
          WHERE (pd.value ->> 'pending')::boolean = true
        )
      SQL

    # For low confidence, require BOTH merchant AND name match (stronger signal needed)
    if merchant_id.present? && name.present?
      name_words = name.downcase.gsub(/[^a-z0-9\s]/, "").split.first(3).join(" ")
      return nil if name_words.blank?

      merchant_matches = candidates.where("transactions.merchant_id = ?", merchant_id).to_a
      name_matches = merchant_matches.select do |c|
        c_name_words = c.name.downcase.gsub(/[^a-z0-9\s]/, "").split.first(3).join(" ")
        name_words == c_name_words
      end

      # Only match if exactly ONE candidate
      return name_matches.first if name_matches.size == 1
    end

    nil
  end

  # Stores a duplicate suggestion on a pending entry for user review
  # The suggestion is stored in the pending transaction's extra field
  #
  # @param pending_entry [Entry] The pending entry that may be a duplicate
  # @param posted_entry [Entry] The posted entry it may match
  # @param reason [String] Why this was flagged (e.g., "fuzzy_amount_match", "low_confidence_match")
  # @param posted_amount [BigDecimal] The posted transaction amount
  # @param confidence [String] Confidence level: "medium" (≤30% diff) or "low" (>30% diff)
  # Auto-detects investment activity label from transaction name and amount
  # Only detects extremely obvious cases to maintain high accuracy
  # Users can always manually adjust the label afterward
  #
  # @param name [String] Transaction name/description
  # @param amount [BigDecimal, Numeric] Transaction amount (positive or negative)
  # @return [String, nil] Detected activity label or nil if no pattern matches
  def detect_activity_label(name, amount)
    return nil if name.blank?

    name_lower = name.downcase.strip

    # Only detect the most obvious patterns - be conservative to avoid false positives
    # Users can manually adjust labels for edge cases
    case name_lower
    when /^dividend\b/, /\bdividend payment\b/, /\bqualified dividend\b/, /\bordinary dividend\b/
      "Dividend"
    when /^interest\b/, /\binterest income\b/, /\binterest payment\b/
      "Interest"
    when /^fee\b/, /\bmanagement fee\b/, /\badvisory fee\b/, /\btransaction fee\b/
      "Fee"
    when /\bemployer match\b/, /\bemployer contribution\b/
      "Contribution"
    when /\b401[k\(]/, /\bira contribution\b/, /\broth contribution\b/
      "Contribution"
    else
      nil # Let user categorize manually - default to nil for safety
    end
  end

  # Determines why an entry should be skipped during sync.
  # Returns nil if entry should NOT be skipped.
  #
  # @param entry [Entry] The entry to check
  # @return [String, nil] Skip reason or nil if entry can be synced
  def determine_skip_reason(entry)
    return "excluded" if entry.excluded?
    return "user_modified" if entry.user_modified?
    return "import_locked" if entry.import_locked?
    return "provider_claimed" if entry.entryable.is_a?(Transaction) && entry.transaction.extra.is_a?(Hash) && entry.transaction.extra.key?("provider_claim")
    nil
  end

  # Records a skipped entry for stats collection.
  #
  # @param entry [Entry, nil] The entry that was skipped (nil when no entry was written)
  # @param reason [String] Why it was skipped
  def record_skip(entry, reason, external_id: nil, date: nil)
    @skipped_entries << {
      id: entry&.id,
      name: entry&.name,
      reason: reason,
      external_id: entry&.external_id || external_id,
      date: entry&.date || date,
      account_name: account.name
    }
  end

  private
    # An account has one valuation per day, and the current anchor moves to today. A
    # reconciliation the user entered today (on an account with hand-kept history) would
    # make that fail and the provider balance would never be written, so it becomes the
    # current anchor (the provider's balance replaces its amount; the old amount is
    # logged), and an older current anchor stays as a reconciliation on its own day. A
    # balance calculated back from the provider ignores reconciliations anyway.
    def make_room_for_current_anchor!(source)
      today = account.entries.valuations.includes(:entryable).find_by(date: Date.current)
      return unless today&.entryable&.reconciliation?

      Account.transaction do
        account.entries.valuations.includes(:entryable).where.not(id: today.id).each do |entry|
          next unless entry.entryable.current_anchor?

          entry.entryable.update!(kind: "reconciliation")
          entry.update!(name: Valuation.build_reconciliation_name(account.accountable_type))
        end
        today.entryable.update!(kind: "current_anchor")
        today.update!(name: Valuation.build_current_anchor_name(account.accountable_type))
      end

      DebugLogEntry.capture(
        category: "sync", level: "info", source: self.class.name, account: account, provider_key: source,
        message: "Today's reconciliation of #{account.name} became the #{source} current balance",
        metadata: { entry_id: today.id, previous_amount: today.amount.to_s }
      )
    end

    def parse_date(date)
      date.is_a?(Date) ? date : Date.parse(date.to_s)
    end

    def transfer_leg?(entry)
      return false if entry.new_record?

      transaction = entry.transaction
      transaction.transfer_as_inflow.present? || transaction.transfer_as_outflow.present? || transaction.fee_transfer_id.present?
    end

    # The entry a new posted row takes over, or nil. An entry passed in must belong to
    # this account and not be owned by a provider yet.
    def resolve_claim(claimed_entry, key:, date:, amount:, currency:, source:, pending: false)
      case claimed_entry
      when :auto
        row = Account::ProviderEntryClaimer::Row.new(key: key, date: parse_date(date), amount: amount.to_d, currency: currency, pending: pending)
        Account::ProviderEntryClaimer.new(account, source: source).match_one(row)
      when Entry
        claimed_entry.reload
        claimed_entry if claimed_entry.account_id == account.id && Account::ProviderEntryClaimer.claimable_id?(claimed_entry) && claimed_entry.entryable.is_a?(Transaction)
      end
    end

    def pending_extra?(extra)
      extra.is_a?(Hash) && extra.values.any? do |provider_data|
        next false unless provider_data.is_a?(Hash)
        ActiveModel::Type::Boolean.new.cast(provider_data["pending"] || provider_data[:pending])
      end
    end

    # Whether entry is an open hold of this provider
    def provider_pending?(entry, source)
      return false unless entry.entryable.is_a?(Transaction)

      data = entry.transaction.extra.is_a?(Hash) ? entry.transaction.extra[source.to_s] : nil
      data.is_a?(Hash) && ActiveModel::Type::Boolean.new.cast(data["pending"]) == true
    end

    # A hold the user edited (or excluded) settles: the bank's amount, date and pending
    # flag are written, so balances add up; the name, category and merchant the user
    # chose stay.
    def settle_protected_hold!(entry, amount:, currency:, date:, extra:)
      entry.update!(amount: amount, currency: currency, date: date)

      if extra.is_a?(Hash)
        transaction = entry.transaction
        transaction.update!(extra: (transaction.extra || {}).deep_merge(extra.deep_stringify_keys))
      end

      entry
    end

    # Remembers that category_id was a guess (the MCC), so a transfer that later makes the
    # transaction an investment contribution may replace it (Transfer#apply_transaction_kinds)
    def note_category_guess(transaction, source, category_id)
      extra = (transaction.extra || {}).deep_dup
      data = extra[source.to_s].is_a?(Hash) ? extra[source.to_s] : {}
      extra[source.to_s] = data.merge("guessed_category_id" => category_id.to_s)
      transaction.extra = extra
    end

    # The provider takes over an entry the user recorded. It keeps its date, amount, name,
    # category, merchant, notes and tags (so balances before and after are the same); it
    # gets the provider's id and metadata and a provider_claim marker, so later syncs leave
    # it alone ("provider_claimed"). An unprotected entry without a category gets
    # category_id_if_blank.
    def claim_entry!(entry, external_id:, source:, extra:, category_id_if_blank:)
      transaction = entry.transaction
      previous_source = entry.source

      entry.update!(external_id: external_id, source: source)

      merged = (transaction.extra || {}).deep_dup
      merged = merged.deep_merge(extra.deep_stringify_keys) if extra.is_a?(Hash)
      merged["provider_claim"] = {
        "source" => source.to_s,
        "claimed_at" => Time.current.iso8601,
        "import_id" => entry.import_id,
        "previous_source" => previous_source
      }
      transaction.extra = merged

      if category_id_if_blank && transaction.category_id.blank? && !entry.protected_from_sync? && !transfer_leg?(entry)
        transaction.enrich_attribute(:category_id, category_id_if_blank, source: source, metadata: { via: "mcc" })
        note_category_guess(transaction, source, transaction.category_id) if transaction.category_id.to_s == category_id_if_blank.to_s
      end

      transaction.save! if transaction.changed?

      @claimed_entries << { id: entry.id, external_id: external_id, date: entry.date }
      Rails.logger.info("#{source} transaction #{external_id} claimed entry #{entry.id} of account #{account.id}")

      entry
    end
end
