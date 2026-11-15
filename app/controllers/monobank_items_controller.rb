# monobank connections: created and changed on Settings > Sync Providers (the
# settings/providers/_monobank_panel partial), products linked from the setup dialog,
# from New account and from an account's "Link provider".
class MonobankItemsController < ApplicationController
  include FamilyAdminRequired
  include ProviderConnectionFlow

  require_bank_connections provider: :monobank
  require_family_admin except: :sync

  PANEL_FRAME = "monobank-providers-panel".freeze

  before_action :set_monobank_item, only: %i[update destroy sync setup_accounts complete_account_setup]
  before_action :set_requested_item, only: %i[select_accounts link_accounts select_existing_account link_existing_account]

  def new
    @monobank_item = Current.family.monobank_items.build(name: t("monobank_items.defaults.name"))
  end

  def create
    @monobank_item = Current.family.monobank_items.build(create_params)
    @monobank_item.name = t("monobank_items.defaults.name") if @monobank_item.name.blank?

    if @monobank_item.save
      @monobank_item.sync_later
      respond_with_panel(notice: t(".success"))
    else
      respond_with_panel(alert: @monobank_item.errors.full_messages.to_sentence, status: :unprocessable_entity)
    end
  end

  def update
    attributes = update_params
    token_changed = attributes[:access_token].present?
    attributes[:status] = "good" if token_changed

    if @monobank_item.update(attributes)
      @monobank_item.sync_later if token_changed
      respond_with_panel(notice: t(".success"))
    else
      respond_with_panel(alert: @monobank_item.errors.full_messages.to_sentence, status: :unprocessable_entity)
    end
  end

  def destroy
    failures = @monobank_item.unlink_all!.select { |result| result[:error].present? }
    if failures.any?
      redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
      return
    end

    @monobank_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  # Also for members who are not admins: syncing changes no settings
  def sync
    unless @monobank_item.syncing?
      @monobank_item.force_forward!
      @monobank_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path, status: :see_other }
      format.json { head :ok }
    end
  end

  def setup_accounts
    @monobank_accounts = @monobank_item.monobank_accounts.needs_setup.ordered.to_a
    @link_candidates = link_candidates_by_currency
    @suggested_links = MonobankAccount.suggest_links(@monobank_accounts, @link_candidates.values.flatten)
  end

  def complete_account_setup
    choices = setup_params
    created = linked = skipped = 0
    errors = []

    @monobank_item.monobank_accounts.needs_setup.where(id: choices.keys).find_each do |monobank_account|
      choice = choices[monobank_account.id].to_h
      action, type, subtype = choice["choice"].to_s.split(":", 3)

      case action
      when "create"
        @monobank_item.create_linked_account!(monobank_account: monobank_account, accountable_type: type, subtype: subtype)
        created += 1
      when "link"
        @monobank_item.link_existing_account!(
          monobank_account: monobank_account,
          account: linkable_accounts.find(type),
          cutover_date: cutover_param(choice["cutover_date"])
        )
        linked += 1
      else
        monobank_account.update!(ignored: true)
        skipped += 1
      end
    rescue ArgumentError, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid,
           Account::ProviderLink::AlreadyLinked, Account::ProviderLink::InvalidCutover => e
      errors << t(".product_failed", name: monobank_account.name, error: e.message)
    end

    @monobank_item.refresh_pending_account_setup!
    flash[:alert] = errors.to_sentence if errors.any?
    flash[:notice] = t(".success", created: created, linked: linked, skipped: skipped) if errors.empty? || created + linked > 0
    redirect_to accounts_path, status: :see_other
  end

  # New account > monobank: products to add as new accounts of one type
  def select_accounts
    @accountable_type = supported_type(params[:accountable_type])
    @return_to = safe_return_to_path
    @monobank_accounts = @monobank_item.monobank_accounts.unlinked.ordered.to_a
    render layout: false
  end

  def link_accounts
    ids = Array(params[:monobank_account_ids]).compact_blank
    accountable_type = supported_type(params[:accountable_type])
    if ids.empty?
      redirect_to link_redirect_target(accounts_path), alert: t(".no_accounts_selected"), status: :see_other
      return
    end

    count = 0
    @monobank_item.monobank_accounts.unlinked.where(id: ids).find_each do |monobank_account|
      type = accountable_type || monobank_account.suggested_account_type || "Depository"
      @monobank_item.create_linked_account!(monobank_account: monobank_account, accountable_type: type)
      count += 1
    end

    redirect_to link_redirect_target(accounts_path), notice: t(".success", count: count), status: :see_other
  rescue ArgumentError, Account::ProviderLink::AlreadyLinked => e
    redirect_to link_redirect_target(accounts_path), alert: t(".failed", error: e.message), status: :see_other
  end

  # Account page > Link provider: the products that can take over this account
  def select_existing_account
    @account = linkable_accounts.find(params.expect(:account_id))
    @monobank_accounts = @monobank_item.monobank_accounts.unlinked.where(currency: @account.currency).ordered.to_a
    @cutover_date = Account::ProviderLink.default_cutover_date(@account)
    @return_to = safe_return_to_path
    render layout: false
  end

  def link_existing_account
    attributes = params.expect(link: %i[account_id monobank_account_id cutover_date])
    account = linkable_accounts.find(attributes[:account_id])
    monobank_account = @monobank_item.monobank_accounts.unlinked.find(attributes[:monobank_account_id])

    @monobank_item.link_existing_account!(monobank_account: monobank_account, account: account,
                                          cutover_date: cutover_param(attributes[:cutover_date]))
    redirect_to link_redirect_target(account_path(account)), notice: t(".success", account_name: account.name), status: :see_other
  rescue ArgumentError, Account::ProviderLink::AlreadyLinked, Account::ProviderLink::InvalidCutover => e
    redirect_to link_redirect_target(accounts_path), alert: t(".failed", error: e.message), status: :see_other
  end

  private
    def set_monobank_item
      @monobank_item = Current.family.monobank_items.find(params[:id])
    end

    def set_requested_item
      scope = Current.family.monobank_items.active.ordered
      id = params[:monobank_item_id].presence || params.dig(:link, :monobank_item_id).presence
      @monobank_item = id ? scope.find(id) : scope.find(&:credentials_configured?)
      raise ActiveRecord::RecordNotFound, "No monobank connection" unless @monobank_item
    end

    def create_params
      params.expect(monobank_item: %i[name access_token sync_start_date include_pending apply_mcc_categories])
    end

    def update_params
      attributes = params.expect(monobank_item: %i[name access_token sync_start_date include_pending apply_mcc_categories])
      attributes.delete(:access_token) if attributes[:access_token].blank?
      attributes
    end

    # { monobank_account_id => { "choice" => "create:Depository:checking" | "link:<id>" | "skip", "cutover_date" => "" } }
    def setup_params
      raw = params.fetch(:setup, {})
      return {} unless raw.respond_to?(:each_pair)

      raw.to_unsafe_h.each_with_object({}) do |(id, value), result|
        next unless value.is_a?(Hash)

        result[id.to_s] = value.slice("choice", "cutover_date")
      end
    end

    def cutover_param(value)
      value.present? ? value.to_s : :auto
    end

    def supported_type(type)
      type if Provider::MonobankAdapter.supported_account_types.include?(type)
    end

    # Manual accounts of the family a product can take over
    def linkable_accounts
      Current.family.accounts.visible_manual.where(accountable_type: Provider::MonobankAdapter.supported_account_types)
    end

    def link_candidates_by_currency
      linkable_accounts.order(:name).to_a.group_by(&:currency)
    end

    def respond_with_panel(notice: nil, alert: nil, status: :ok)
      if turbo_frame_request?
        flash.now[:notice] = notice if notice
        flash.now[:alert] = alert if alert
        render turbo_stream: [
          turbo_stream.update(PANEL_FRAME, partial: "settings/providers/monobank_panel", locals: { error_message: alert }),
          *flash_notification_stream_items
        ], status: status
      else
        redirect_to settings_providers_path, notice: notice, alert: alert, status: :see_other
      end
    end
end
