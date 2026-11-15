# Links an account to a provider account (an AccountProvider row) and undoes it.
#
# An account with manual history keeps it: link! stores a cutover date, the day the
# provider takes over. Entries before it stay as the user entered them, balances
# before it are still calculated forward from the opening anchor, and the provider's
# rows dated before it are not imported (Account::ProviderImportAdapter). From the
# cutover date on, the balance comes back from the provider's current balance
# (Account#balance_strategy :cutover, Balance::CutoverCalculator).
#
#   Account::ProviderLink.link!(account: mono_visa, provider_account: monobank_account)
#   Account::ProviderLink.unlink!(mono_visa)
module Account::ProviderLink
  class AlreadyLinked < StandardError; end
  class InvalidCutover < StandardError; end

  class << self
    # cutover_date: :auto (default_cutover_date), a Date (today or earlier and after the
    # account's opening anchor), or nil (no cutover: the provider owns the whole
    # history). A provider account that keeps fetch state (reset_fetch_state!) forgets
    # it, so the history the new link needs is fetched again, also after an unlink.
    # Does not enqueue a sync; the caller syncs the provider item.
    def link!(account:, provider_account:, cutover_date: :auto)
      account.with_lock do
        raise AlreadyLinked, "Account #{account.id} is already linked" if account.account_providers.exists? || account.plaid_account_id.present?
        raise AlreadyLinked, "#{provider_account.class.name} #{provider_account.id} is already linked" if AccountProvider.exists?(provider: provider_account)

        cutover = resolve_cutover(account, cutover_date)
        link = AccountProvider.create!(account: account, provider: provider_account, cutover_date: cutover)
        provider_account.reset_fetch_state! if provider_account.respond_to?(:reset_fetch_state!)
        link
      end
    rescue ActiveRecord::RecordNotUnique
      raise AlreadyLinked, "Account #{account.id} or #{provider_account.class.name} #{provider_account.id} is already linked"
    ensure
      account.account_providers.reset
    end

    # The day after the latest transaction or trade dated today or earlier, but never
    # after today; nil when the account has none (a new or empty account). Future-dated
    # entries are ignored.
    def default_cutover_date(account)
      latest = account.entries.where.not(entryable_type: "Valuation").where(date: ..Date.current).maximum(:date)
      return nil unless latest

      [ latest + 1.day, Date.current ].min
    end

    # Turns the account back into a manual one. Its balance today and its history stay
    # as they are: a cutover account gets a reconciliation on the cutover date with the
    # balance it had there, the opening anchor of an account calculated back from the
    # provider takes the balance the day after it started from, and the provider's
    # current anchors become reconciliations,
    # so the forward calculation that manual accounts use gives the same numbers. The
    # provider's entries stay; open holds of a provider whose balance counts them
    # become ordinary entries (the forward calculation leaves pending entries out, and
    # nothing would ever settle or remove them). Enqueues a sync.
    def unlink!(account)
      Account.transaction do
        account.lock!

        strategy = account.balance_strategy
        write_cutover_reconciliation(account) if strategy == :cutover
        carry_reverse_opening_balance(account) if strategy == :reverse
        settle_open_holds(account)
        convert_current_anchors(account)

        link_ids = account.account_providers.pluck(:id)
        Holding.where(account_provider_id: link_ids).update_all(account_provider_id: nil) if link_ids.any?

        account.account_providers.destroy_all
        account.update!(plaid_account_id: nil)
      end

      account.account_providers.reset
      account.sync_later
      true
    end

    private
      def resolve_cutover(account, cutover_date)
        return default_cutover_date(account) if cutover_date == :auto
        return nil if cutover_date.nil? || cutover_date == ""

        date = cutover_date.is_a?(Date) ? cutover_date : Date.parse(cutover_date.to_s)
        raise InvalidCutover, "Cutover date #{date} is in the future" if date > Date.current
        # On or before the opening anchor there is no hand-kept history to keep: the
        # account would be calculated back from the provider in full
        if account.has_opening_anchor? && date <= account.opening_anchor_date
          raise InvalidCutover, "Cutover date #{date} must be after the opening balance date #{account.opening_anchor_date}"
        end

        date
      rescue Date::Error
        raise InvalidCutover, "Cutover date #{cutover_date.inspect} is not a date"
      end

      # The stored end balance on the cutover date (the provider's figure, drift included)
      def write_cutover_reconciliation(account)
        cutover = account.provider_cutover_date
        balance = account.balances.where(date: cutover, currency: account.currency).pick(:end_balance)
        return if balance.nil?

        existing = account.entries.valuations.find_by(date: cutover)
        if existing
          # An anchor on that day keeps its role; any other valuation takes the balance
          return unless existing.entryable.reconciliation?

          existing.update!(amount: balance)
        else
          account.entries.create!(
            date: cutover,
            name: Valuation.build_reconciliation_name(account.accountable_type),
            amount: balance,
            currency: account.currency,
            entryable: Valuation.new(kind: "reconciliation")
          )
        end
      end

      # The reverse calculation shows the opening anchor only on its own day; the day
      # after starts from the provider's figure. The anchor takes that figure, so the
      # forward calculation from it gives the same history (e.g. an account a provider
      # created whose history backfill had not finished).
      def carry_reverse_opening_balance(account)
        return unless account.has_opening_anchor?

        opening_date = account.opening_anchor_date
        start = account.balances.where(currency: account.currency).where("date > ?", opening_date).order(:date).pick(:start_balance)
        return if start.nil? || start == account.opening_anchor_balance

        account.set_opening_anchor_balance(balance: start)
      end

      def settle_open_holds(account)
        account.account_providers.each do |link|
          provider = BankConnections.provider_for_account_class(link.provider_type)
          next unless provider&.balance_includes_pending?

          account.entries.pending_from(provider.key).where.not(Transaction.released_hold_sql("transactions")).includes(:entryable).find_each do |entry|
            extra = (entry.entryable.extra || {}).deep_dup
            data = extra[provider.key].is_a?(Hash) ? extra[provider.key] : {}
            data.delete("pending")
            data["unlinked_while_pending_at"] = Time.current.iso8601
            extra[provider.key] = data
            entry.entryable.update!(extra: extra)
          end
        end
      end

      def convert_current_anchors(account)
        account.entries.valuations
          .joins("INNER JOIN valuations ON valuations.id = entries.entryable_id")
          .where(valuations: { kind: "current_anchor" })
          .find_each do |entry|
            entry.entryable.update!(kind: "reconciliation")
            entry.update!(name: Valuation.build_reconciliation_name(account.accountable_type))
          end
      end
  end
end
