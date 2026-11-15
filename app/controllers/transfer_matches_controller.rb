class TransferMatchesController < ApplicationController
  before_action :set_entry

  def new
    @accounts = Current.family.accounts.visible.alphabetically.where.not(id: @entry.account_id)
    @transfer_match_candidates = @entry.transaction.transfer_match_candidates
  end

  def create
    @transfer = build_transfer

    # A new transfer sets the legs' kinds itself (Transfer after_create). Matching an
    # existing auto-matched pair confirms it.
    if @transfer.persisted?
      @transfer.confirm! if @transfer.may_confirm?
    else
      @transfer.save!
    end

    @transfer.sync_account_later

    redirect_back_or_to transactions_path, notice: t(".success")
  end

  # w2-transfers transfer-hints: "Not a transfer" on the list's "Transfer?" hint. Records
  # the hint's pairs as rejected and removes the hint from the row in place.
  def destroy
    Current.family.dismiss_transfer_hint!(@entry.transaction)

    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove(helpers.dom_id(@entry.transaction, :transfer_hint)) }
      format.html { redirect_back_or_to transactions_path }
    end
  end

  private
    def set_entry
      @entry = Current.family.entries.find(params[:transaction_id])
    end

    def transfer_match_params
      params.expect(transfer_match: [ :method, :matched_entry_id, :target_account_id ])
    end

    def build_transfer
      if transfer_match_params[:method] == "new"
        target_account = Current.family.accounts.find(transfer_match_params[:target_account_id])

        missing_transaction = Transaction.new(
          entry: target_account.entries.build(
            amount: @entry.amount * -1,
            currency: @entry.currency,
            date: @entry.date,
            name: "Transfer to #{@entry.amount.negative? ? @entry.account.name : target_account.name}",
          )
        )

        transfer = Transfer.find_or_initialize_by(
          inflow_transaction: @entry.amount.positive? ? missing_transaction : @entry.transaction,
          outflow_transaction: @entry.amount.positive? ? @entry.transaction : missing_transaction
        )
        transfer.status = "confirmed" if transfer.new_record?
        transfer
      else
        target_transaction = Current.family.entries.find(transfer_match_params[:matched_entry_id])

        transfer = Transfer.find_or_initialize_by(
          inflow_transaction: @entry.amount.negative? ? @entry.transaction : target_transaction.transaction,
          outflow_transaction: @entry.amount.negative? ? target_transaction.transaction : @entry.transaction
        )
        transfer.status = "confirmed" if transfer.new_record?
        transfer
      end
    end
end
