class PropertiesController < ApplicationController
  include AccountableResource, StreamExtensions

  before_action :set_property, only: [ :balances, :address, :update_balances, :update_address ]

  def new
    @account = Current.family.accounts.build(accountable: Property.new)
  end

  def create
    @account = Current.family.accounts.create!(
      property_params.merge(
        accountable_type: "Property",
        currency: property_params[:currency].presence || Current.family.currency,
        balance: 0,
        status: "draft"
      )
    )

    redirect_to balances_property_path(@account)
  end

  def update
    if @account.update(property_params.except(:accountable_type))
      currency_changed = @account.saved_change_to_currency?
      @account.lock_saved_attributes!
      # Balances are stored in the account currency, so they are rebuilt in the new one.
      # A draft gets no sync until its wizard is finished.
      @account.sync_later if currency_changed && @account.active?
      @success_message = t(".success")

      if @account.active?
        render :edit
      else
        redirect_to balances_property_path(@account)
      end
    else
      @error_message = t(".failure")
      render :edit, status: :unprocessable_entity
    end
  end

  def edit
  end

  def balances
  end

  def update_balances
    # The value and its currency are one form: both commit or neither does
    result = nil
    Account.transaction do
      new_currency = balance_params[:currency].presence
      @account.update!(currency: new_currency) if new_currency && new_currency != @account.currency
      result = @account.set_current_balance(balance_params[:balance].to_d)
      raise ActiveRecord::Rollback unless result.success?
    end

    if result.success?
      @success_message = t(".success")

      if @account.active?
        render :balances
      else
        redirect_to address_property_path(@account)
      end
    else
      @error_message = result.error
      render :balances, status: :unprocessable_entity
    end
  end

  def address
    @property = @account.property
    @property.address ||= Address.new
  end

  def update_address
    # A draft is activated by this, the last step, so the balance step must be done first.
    if @account.draft? && !balance_step_complete?
      redirect_to balances_property_path(@account), alert: t(".balance_required")
      return
    end

    if @account.property.update(address_params)
      if @account.draft?
        @account.activate!
        # A draft gets no sync while it is set up, and totals skip it until now.
        @account.sync_later

        # The wizard (create, value, address) does not thread `?return_to=` through
        # its steps, so only the session (StoreLocation) still has it. Sanitized here
        # too: Rails' redirect host guard does not cover stream_redirect_to.
        return_path = sanitize_return_to(session.delete(:return_to)) || account_path(@account)

        respond_to do |format|
          format.html { redirect_to return_path }
          format.turbo_stream { stream_redirect_to return_path }
        end
      else
        @success_message = t(".success")
        render :address
      end
    else
      @error_message = t(".failure")
      render :address, status: :unprocessable_entity
    end
  end

  private
    def balance_params
      params.expect(account: [ :balance, :currency ])
    end

    def address_params
      params.expect(property: [ address_attributes: [ :line1, :line2, :locality, :region, :country, :postal_code ] ])
    end

    def property_params
      params.expect(account: [
        :name,
        :currency,
        :accountable_type,
        :institution_name,
        :institution_domain,
        :notes,
        accountable_attributes: [ :id, :subtype, :year_built, :area_unit, :area_value ]
      ])
    end

    # Only properties: other account types have no `property`, and the property forms
    # would write property attributes onto them.
    def set_property
      @account = Current.family.accounts.where(accountable_type: "Property").find(params[:id])
      @property = @account.property
    end

    # AccountableResource's lookup for show, edit and update.
    def set_account
      set_property
    end

    # The balance step stores the value as a valuation entry.
    def balance_step_complete?
      @account.entries.valuations.exists?
    end
end
