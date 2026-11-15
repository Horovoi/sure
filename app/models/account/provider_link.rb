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
    # cutover_date: :auto (default_cutover_date), a Date (today or earlier), or nil
    # (no cutover: the provider owns the whole history). Does not enqueue a sync;
    # the caller syncs the provider item.
    def link!(account:, provider_account:, cutover_date: :auto)
      account.with_lock do
        raise AlreadyLinked, "Account #{account.id} is already linked" if account.account_providers.exists? || account.plaid_account_id.present?
        raise AlreadyLinked, "#{provider_account.class.name} #{provider_account.id} is already linked" if AccountProvider.exists?(provider: provider_account)

        cutover = resolve_cutover(account, cutover_date)
        AccountProvider.create!(account: account, provider: provider_account, cutover_date: cutover)
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
    # balance it had there, and the provider's current anchors become reconciliations,
    # so the forward calculation that manual accounts use gives the same numbers. The
    # provider's entries stay. Enqueues a sync.
    def unlink!(account)
      Account.transaction do
        account.lock!

        write_cutover_reconciliation(account) if account.balance_strategy == :cutover
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
