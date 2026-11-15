module MonobankItem::Unlinking
  extend ActiveSupport::Concern

  # Unlinks every product from its Sure account through Account::ProviderLink, which
  # keeps today's balance and the history. With dry_run only reports what it would do.
  # Returns one result per product, with :error when that product could not be unlinked.
  def unlink_all!(dry_run: false)
    monobank_accounts.includes(account_provider: :account).map do |monobank_account|
      account = monobank_account.current_account
      result = { provider_account_id: monobank_account.id, name: monobank_account.name, account_id: account&.id }
      next result if dry_run || account.nil?

      begin
        Account::ProviderLink.unlink!(account)
      rescue => e
        capture_error("Failed to unlink monobank account", e, monobank_account: monobank_account, level: "warn")
        result[:error] = e.message
      end
      result
    end
  end
end
