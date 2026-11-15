class TransfersController < ApplicationController
  include StreamExtensions

  before_action :set_transfer, only: %i[show destroy update]

  def new
    @transfer = Transfer.new
    @from_account_id = params[:from_account_id]
  end

  def show
    @categories = Current.family.categories.expenses.alphabetically_by_hierarchy.to_a
    @recent_categories = Category.recently_used_for(
      family: Current.family,
      excluding: @transfer.outflow_transaction.category,
      classification: "expense"
    ).to_a
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
      amount: transfer_params[:amount].to_d,
      exchange_rate: transfer_params[:exchange_rate].presence,
      destination_amount: transfer_params[:destination_amount].presence,
      source_fee: transfer_params[:source_fee].presence,
      destination_fee: transfer_params[:destination_fee].presence
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
    @view_ctx = view_ctx_from_referer
    rejecting = transfer_update_params[:status] == "rejected"

    Transfer.transaction do
      # Locked, so a confirmation landing meanwhile cannot change what the response assumes
      @transfer.lock!
      @rejected_pending_match = rejecting && @transfer.pending?
      update_transfer_status
      update_transfer_details unless rejecting
    end

    respond_to do |format|
      format.html { redirect_back_or_to transactions_url, notice: t(".success") }
      format.turbo_stream do
        if rejecting
          respond_to_rejection
        else
          render :update
        end
      end
    end
  end

  # "Remove transfer" means "these two are not a transfer": record a rejection so the next
  # sync's auto-match does not pair them again.
  def destroy
    @transfer.reject!
    redirect_back_or_to transactions_url, notice: t(".success")
  end

  private
    # w2-transfers transfer-hints: rejecting a pending match redraws its two rows in place,
    # without a page reload, when that is enough: the match changed neither leg (so the
    # page's totals stay right) and the page is an account page, which draws each leg on
    # its own. Every other list draws a transfer once, by its outflow, so the freed inflow
    # has no row to redraw there, and a confirmed transfer's legs go back to income and
    # spending; the page reloads in those cases.
    def respond_to_rejection
      unless @rejected_pending_match && @view_ctx == "account"
        stream_redirect_to(request.referer.presence || transactions_url, notice: t(".rejected"))
        return
      end

      # Loaded again: the transfer's own legs still hold it in memory and would draw the pill
      @redrawn_entries = Entry.where(entryable_type: "Transaction", entryable_id: [ @transfer.inflow_transaction_id, @transfer.outflow_transaction_id ])
                              .includes(:account, entryable: Transaction::ROW_ASSOCIATIONS)
                              .to_a
      @transfer_hint_transaction_ids = Current.family.transaction_ids_with_transfer_candidates(@redrawn_entries.map(&:entryable))
      render :reject
    end

    # How the page that asked draws its rows: an account page of one of the legs signs each
    # leg for its own account, every other list shows a transfer as +/-. Taken from the
    # Referer rather than from a parameter, so a stale button cannot claim a view the page
    # does not have.
    def view_ctx_from_referer
      path = URI.parse(request.referer.to_s).path
      return "global" if path.blank?

      leg_account_ids = Entry.where(entryable_type: "Transaction", entryable_id: [ @transfer.inflow_transaction_id, @transfer.outflow_transaction_id ]).pluck(:account_id)
      leg_account_ids.any? { |id| path == account_path(id) } ? "account" : "global"
    rescue URI::InvalidURIError
      "global"
    end

    def set_transfer
      # Finds the transfer and ensures the family owns it
      @transfer = Transfer
                    .where(id: params[:id])
                    .where(inflow_transaction_id: Current.family.transactions.select(:id))
                    .first!
    end

    def transfer_params
      params.expect(transfer: [ :from_account_id, :to_account_id, :amount, :date, :name, :excluded, :exchange_rate, :destination_amount, :source_fee, :destination_fee ])
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
      params.expect(transfer: [ :notes, :status, :category_id, :source_fee, :destination_fee ])
    end

    def update_transfer_status
      if transfer_update_params[:status] == "rejected"
        @transfer.reject!
      elsif transfer_update_params[:status] == "confirmed"
        @transfer.confirm! if @transfer.may_confirm?
      end
    end

    # Only the fields the request sent: the row's "Confirm" button sends just
    # the status, and must not wipe the category and notes.
    def update_transfer_details
      if transfer_update_params.key?(:category_id)
        @transfer.outflow_transaction.update!(category_id: transfer_update_params[:category_id])
        @transfer.outflow_transaction.record_category_usage!
      end

      @transfer.update!(notes: transfer_update_params[:notes]) if transfer_update_params.key?(:notes)
      update_transfer_fees
    end

    # w2-transfers transfer-fees: the drawer's fee fields. A blank field removes that
    # side's fee; a value that is not an amount is left alone.
    def update_transfer_fees
      Transfer::FEE_SIDES.each do |side|
        key = :"#{side}_fee"
        next unless transfer_update_params.key?(key)

        raw = transfer_update_params[key]
        amount = UserDecimal.parse(raw)
        next if raw.present? && (amount.nil? || amount.negative?)

        next unless @transfer.set_fee!(side: side, amount: amount)

        @fees_changed = true
        @transfer.fee_account_for(side).sync_later
      end
    end
end
