class TransfersController < ApplicationController
  include StreamExtensions

  before_action :set_transfer, only: %i[show destroy update]

  def new
    @transfer = Transfer.new
    @from_account_id = params[:from_account_id]
  end

  def show
    @categories = Current.family.categories.expenses
  end

  def create
    date = parse_transfer_date

    if date.nil?
      # Without a date the creator cannot convert the amount or compare the legs' dates,
      # so show the form again with the error instead of building the legs.
      @transfer = Transfer.new
      @transfer.errors.add(:date, transfer_params[:date].blank? ? :blank : :invalid)
      render :new, status: :unprocessable_entity
      return
    end

    @transfer = Transfer::Creator.new(
      family: Current.family,
      source_account_id: transfer_params[:from_account_id],
      destination_account_id: transfer_params[:to_account_id],
      date: date,
      amount: transfer_params[:amount].to_d
    ).create

    if @transfer.persisted?
      success_message = t(".success")
      respond_to do |format|
        format.html { redirect_back_or_to transactions_path, notice: success_message }
        format.turbo_stream { stream_redirect_back_or_to transactions_path, notice: success_message }
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    Transfer.transaction do
      update_transfer_status
      update_transfer_details unless transfer_update_params[:status] == "rejected"
    end

    respond_to do |format|
      format.html { redirect_back_or_to transactions_url, notice: t(".success") }
      format.turbo_stream
    end
  end

  # "Remove transfer" means "these two are not a transfer": record a rejection so the next
  # sync's auto-match does not pair them again.
  def destroy
    @transfer.reject!
    redirect_back_or_to transactions_url, notice: t(".success")
  end

  private
    def set_transfer
      # Finds the transfer and ensures the family owns it
      @transfer = Transfer
                    .where(id: params[:id])
                    .where(inflow_transaction_id: Current.family.transactions.select(:id))
                    .first!
    end

    def transfer_params
      params.expect(transfer: [ :from_account_id, :to_account_id, :amount, :date, :name, :excluded ])
    end

    # Parsing raises on a bad value, which would be a 500; a blank or bad date is nil.
    def parse_transfer_date
      value = transfer_params[:date]
      return if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError # Date::Error, and the error for an over-long string
      nil
    end

    def transfer_update_params
      params.expect(transfer: [ :notes, :status, :category_id ])
    end

    def update_transfer_status
      if transfer_update_params[:status] == "rejected"
        @transfer.reject!
      elsif transfer_update_params[:status] == "confirmed"
        @transfer.confirm! if @transfer.may_confirm?
      end
    end

    def update_transfer_details
      @transfer.outflow_transaction.update!(category_id: transfer_update_params[:category_id])
      @transfer.update!(notes: transfer_update_params[:notes])
    end
end
