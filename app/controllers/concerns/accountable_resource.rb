module AccountableResource
  extend ActiveSupport::Concern

  included do
    include Periodable

    before_action :set_account, only: [ :show, :edit, :update ]
    before_action :set_link_options, only: :new
  end

  class_methods do
    def permitted_accountable_attributes(*attrs)
      @permitted_accountable_attributes = attrs if attrs.any?
      @permitted_accountable_attributes ||= [ :id ]
    end
  end

  def new
    @account = Current.family.accounts.build(
      currency: Current.family.currency,
      accountable: accountable_type.new
    )
  end

  def show
    @chart_view = params[:chart_view].presence || "balance"
    @q = params.fetch(:q, {}).permit(:search)
    entries = @account.entries.search(@q).reverse_chronological

    @pagy, @entries = pagy(entries, limit: safe_per_page(10))
  end

  def edit
  end

  def create
    opening_balance_date, date_error = parse_opening_balance_date(account_params[:opening_balance_date])

    if date_error
      @account = rebuilt_account_from_submission
      @error_message = date_error
      set_link_options
      render :new, status: :unprocessable_entity
      return
    end

    Account.transaction do
      @account = Current.family.accounts.create_and_sync(
        account_params.except(:return_to, :opening_balance_date),
        opening_balance_date: opening_balance_date
      )
      @account.lock_saved_attributes!
    end

    # The form's return_to first, then the one StoreLocation kept in the session from
    # `?return_to=` (multi-step flows do not thread it through), then the account page.
    # The session value is consumed so a stale one cannot redirect a later flow.
    return_path = sanitize_return_to(account_params[:return_to]) ||
                  sanitize_return_to(session.delete(:return_to)) ||
                  @account
    redirect_to return_path, notice: t("accounts.create.success", type: accountable_type.name.underscore.humanize)
  rescue ActiveRecord::RecordInvalid => e
    # A validation the user can trip from the form comes back as the form with the
    # error and what they typed; the transaction above has rolled back. The record on
    # the exception is usually the unsaved account, but the opening valuation or the
    # accountable can raise too, and the form cannot render those.
    @account = if e.record.is_a?(Account)
      e.record
    else
      e.record.try(:account) || rebuilt_account_from_submission
    end
    @error_message = e.record.errors.full_messages.join(", ").presence || e.message
    # The `new` template's method selection reads @provider_configs
    set_link_options
    render :new, status: :unprocessable_entity
  end

  def update
    # Kept for the 422 form when a step fails. The type is fixed once the account
    # exists: its accountable row is of that type.
    update_params = account_params.except(:return_to, :balance, :opening_balance_date, :accountable_type)
    new_currency = update_params.delete(:currency).presence

    # The currency, the balance and the other fields are one form: they commit or
    # roll back together.
    saved = Account.transaction do
      # The currency first, so a new balance is stored in the currency it was typed in
      currency_changed = new_currency.present? && new_currency != @account.currency
      @account.update!(currency: new_currency) if currency_changed

      balance_changed = account_params[:balance].present? && account_params[:balance].to_d != @account.balance
      if balance_changed
        result = @account.set_current_balance(account_params[:balance].to_d)
        unless result.success?
          @account.assign_attributes(update_params)
          @error_message = result.error
          raise ActiveRecord::Rollback
        end
      end

      unless @account.update(update_params)
        @error_message = @account.errors.full_messages.join(", ")
        raise ActiveRecord::Rollback
      end

      @account.lock_saved_attributes!

      # Balances are stored in the account currency, so they are rebuilt in the new one.
      # set_current_balance already queued a sync.
      @account.sync_later if currency_changed && !balance_changed

      true
    rescue ActiveRecord::RecordInvalid => e
      @error_message = e.record.errors.full_messages.join(", ").presence || e.message
      raise ActiveRecord::Rollback
    end

    unless saved
      render :edit, status: :unprocessable_entity
      return
    end

    redirect_back_or_to account_path(@account), notice: t("accounts.update.success", type: accountable_type.name.underscore.humanize)
  end

  private
    # [date, error]. A blank date gives nil (the opening balance manager's default,
    # two years ago); a malformed or future date gives an error for the form.
    def parse_opening_balance_date(value)
      return [ nil, nil ] if value.blank?

      date = Date.iso8601(value.to_s)
      return [ nil, t("accounts.create.opening_balance_date_future") ] if date > Date.current

      [ date, nil ]
    rescue Date::Error
      [ nil, t("accounts.create.opening_balance_date_invalid") ]
    end

    # The account the 422 form renders when the exception carried none, built from
    # what was submitted so the form comes back filled in. accountable_attributes is
    # defaulted as create_and_sync does: `accountable_type=` alone does not build the
    # accountable, and without one the form loses the type's own fields.
    def rebuilt_account_from_submission
      attributes = account_params.except(:return_to, :opening_balance_date)
      attributes[:accountable_attributes] ||= {}
      Current.family.accounts.build(attributes)
    end

    def set_link_options
      return @provider_configs = [] unless BankConnections.enabled?

      account_type_name = accountable_type.name

      # Get all available provider configs dynamically for this account type
      @provider_configs = Provider::Factory.connection_configs_for_account_type(
        account_type: account_type_name,
        family: Current.family
      )
    end

    def accountable_type
      controller_name.classify.constantize
    end

    def set_account
      @account = Current.family.accounts.find(params[:id])
    end

    def account_params
      params.expect(account: [
        :name, :balance, :subtype, :currency, :accountable_type, :return_to,
        :opening_balance_date,
        :institution_name, :institution_domain, :notes,
        accountable_attributes: self.class.permitted_accountable_attributes
      ])
    end
end
