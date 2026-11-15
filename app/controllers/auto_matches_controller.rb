# The review page for transfer auto-matches: every pending transfer of the family, to
# confirm or reject one by one or in bulk. A pending match is a suggestion that leaves both
# legs as they are, so nothing here changes a figure until the user confirms.
#
# Confirm and reject go through the Transfer's own confirm! and reject!, the only writers of
# the legs' kinds. Each one locks the transfer row and checks it is still pending, so a match
# another tab or the transaction list resolved meanwhile is skipped, not resolved twice.
class AutoMatchesController < ApplicationController
  include SafePagination

  layout "settings"

  before_action :set_transfer, only: %i[confirm reject]

  def index
    @pagy, @pending_transfers = pagy(
      pending_transfers
        .includes(inflow_transaction: [ :merchant, { entry: :account } ], outflow_transaction: [ :merchant, { entry: :account } ])
        .order(created_at: :desc),
      limit: safe_per_page(30)
    )
  end

  def confirm
    resolved = resolve(@transfer, :confirm)
    redirect_to auto_matches_path, notice: t(resolved ? ".success" : "auto_matches.already_resolved")
  end

  def reject
    resolved = resolve(@transfer, :reject)
    redirect_to auto_matches_path, notice: t(resolved ? ".success" : "auto_matches.already_resolved")
  end

  def bulk_update
    status = bulk_update_params[:status]
    transfer_ids = Array(bulk_update_params[:transfer_ids]).compact_blank

    unless status.in?(%w[confirmed rejected]) && transfer_ids.any?
      redirect_to auto_matches_path, alert: t(".invalid_selection")
      return
    end

    action = status == "confirmed" ? :confirm : :reject
    count = pending_transfers.where(id: transfer_ids).to_a.count { |transfer| resolve(transfer, action) }

    redirect_to auto_matches_path, notice: t(".#{status}", count: count)
  end

  private
    # Transfers of this family whose both legs belong to it
    def pending_transfers
      family_transaction_ids = Current.family.transactions.select(:id)

      Transfer.pending
        .where(inflow_transaction_id: family_transaction_ids)
        .where(outflow_transaction_id: family_transaction_ids)
    end

    def set_transfer
      @transfer = pending_transfers.find_by(id: params.expect(:id))
      redirect_to auto_matches_path, notice: t("auto_matches.already_resolved") unless @transfer
    end

    # True when this request resolved the match; false when it was no longer pending
    def resolve(transfer, action)
      resolved = false

      transfer.with_lock do
        next unless transfer.pending?

        action == :confirm ? transfer.confirm! : transfer.reject!
        resolved = true
      end

      # No account sync: a kind changes no balance, and the entry touch from the leg's save
      # refreshes the cached reports
      resolved
    rescue ActiveRecord::RecordNotFound
      # Rejected (destroyed) by a concurrent request
      false
    end

    # permit, not expect: an empty selection sends no transfer_ids and must get the alert
    # below, not a 400
    def bulk_update_params
      params.permit(:status, transfer_ids: [])
    end
end
