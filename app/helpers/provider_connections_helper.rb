# View helpers shared by the bank connection panels and account pages.
module ProviderConnectionsHelper
  # state: :deleting, :requires_update, :syncing, :fetching, :error, :ok or :never. A
  # product whose statement keeps failing (backfill_progress[:failing]) is an :error.
  Status = Data.define(:state, :text)

  # "Transactions from 14 Nov 2026 come from monobank. Earlier history is kept as you
  # entered it." for an account a provider took over at a cutover date, else nil
  def provider_cutover_text(account)
    return nil unless account.linked?

    cutover = account.provider_cutover_date
    return nil unless cutover

    t("provider_connections.cutover_text", date: format_date(cutover), provider: provider_label_for(account))
  end

  # Whether an enabled bank connection provider can link an account of this type, for
  # the "Link provider" button. Read once per account type and request.
  def provider_link_available?(account)
    return false unless BankConnections.enabled?

    @provider_link_available ||= {}
    @provider_link_available.fetch(account.accountable_type) do
      @provider_link_available[account.accountable_type] = Provider::Factory.connection_configs_for_account_type(
        account_type: account.accountable_type, family: account.family
      ).any?
    end
  end

  # One status line for a provider item (a *_item record)
  def provider_item_status(item)
    if item.respond_to?(:scheduled_for_deletion?) && item.scheduled_for_deletion?
      Status.new(state: :deleting, text: t("provider_connections.status.deleting"))
    elsif item.respond_to?(:requires_update?) && item.requires_update?
      Status.new(state: :requires_update, text: t("provider_connections.status.requires_update"))
    elsif item.syncing?
      Status.new(state: :syncing, text: t("provider_connections.status.syncing"))
    elsif (progress = backfill_progress_for(item)) && progress[:failing].present?
      Status.new(state: :error, text: failing_text(progress[:failing]))
    elsif progress && progress[:chain_active]
      Status.new(state: :fetching, text: fetching_text(progress))
    elsif item.sync_error.present?
      Status.new(state: :error, text: t("provider_connections.status.error", error: item.sync_error))
    elsif item.last_synced_at
      Status.new(state: :ok, text: t("provider_connections.status.ok", time: time_ago_in_words(item.last_synced_at)))
    else
      Status.new(state: :never, text: t("provider_connections.status.never"))
    end
  end

  private
    def provider_label_for(account)
      link = account.account_providers.first
      provider = link && BankConnections.provider_for_account_class(link.provider_type)
      provider&.label || account.provider_name.to_s.humanize
    end

    def backfill_progress_for(item)
      item.respond_to?(:backfill_progress) ? item.backfill_progress : nil
    end

    def failing_text(failing)
      names = failing.map { |product| product[:name] }.to_sentence
      t("provider_connections.status.failing", count: failing.size, names: names)
    end

    def fetching_text(progress)
      windows = progress[:windows_remaining].to_i
      minutes = (progress[:eta_seconds].to_i / 60.0).ceil

      if windows.positive?
        t("provider_connections.status.fetching", count: windows, minutes: [ minutes, 1 ].max)
      else
        t("provider_connections.status.fetching_finishing")
      end
    end
end
