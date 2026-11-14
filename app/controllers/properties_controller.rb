class PropertiesController < ApplicationController
  include AccountableResource, StreamExtensions

  before_action :set_property, only: [ :balances, :address, :update_balances, :update_address ]

  def new
    @account = Current.family.accounts.build(accountable: Property.new)
  end

  def create
    @account = Current.family.accounts.create!(
      property_params.merge(accountable_type: "Property", currency: Current.family.currency, balance: 0, status: "draft")
    )

    redirect_to balances_property_path(@account)
  end

  def update
    if @account.update(property_params.except(:accountable_type))
      @account.lock_saved_attributes!
      @success_message = "Property details updated successfully."

      if @account.active?
        render :edit
      else
        redirect_to balances_property_path(@account)
      end
    else
      @error_message = "Unable to update property details."
      render :edit, status: :unprocessable_entity
    end
  end

  def edit
  end

  def balances
  end

  def update_balances
    result = @account.set_current_balance(balance_params[:balance].to_d)

    if result.success?
      @success_message = "Balance updated successfully."

      if @account.active?
        render :balances
      else
        redirect_to address_property_path(@account)
      end
    else
      @error_message = result.error_message
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

        respond_to do |format|
          format.html { redirect_to account_path(@account) }
          format.turbo_stream { stream_redirect_to account_path(@account) }
        end
      else
        @success_message = "Address updated successfully."
        render :address
      end
    else
      @error_message = "Unable to update address. Please check the required fields."
      render :address, status: :unprocessable_entity
    end
  end

  private
    def balance_params
      params.require(:account).permit(:balance, :currency)
    end

    def address_params
      params.require(:property)
            .permit(address_attributes: [ :line1, :line2, :locality, :region, :country, :postal_code ])
    end

    def property_params
      params.require(:account)
            .permit(
              :name,
              :accountable_type,
              :institution_name,
              :institution_domain,
              :notes,
              accountable_attributes: [ :id, :subtype, :year_built, :area_unit, :area_value ]
            )
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
