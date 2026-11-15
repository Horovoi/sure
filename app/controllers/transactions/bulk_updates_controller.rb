class Transactions::BulkUpdatesController < ApplicationController
  def new
  end

  def create
    # An unknown status would raise inside the batch; refuse it before anything changes
    reconciled_status = bulk_update_params[:reconciled_status]
    if reconciled_status.present? && !Entry.reconciled_statuses.key?(reconciled_status)
      redirect_back_or_to transactions_path, alert: t("transactions.reconcile.failure")
      return
    end

    updated = Current.family
                     .entries
                     .where(id: bulk_update_params[:entry_ids])
                     .includes(:entryable)
                     .bulk_update!(bulk_update_params, update_tags: tags_provided?)

    redirect_back_or_to transactions_path, notice: t(".success", count: updated)
  rescue ActiveRecord::RecordInvalid => e
    # The whole batch rolls back (e.g. two balance updates moved to the same date)
    redirect_back_or_to transactions_path, alert: t(".invalid", errors: e.record.errors.full_messages.to_sentence)
  end

  private
    def bulk_update_params
      params.expect(bulk_update: [ :date, :notes, :name, :category_id, :merchant_id, :reconciled_status, entry_ids: [], tag_ids: [] ])
    end

    def tags_provided?
      bulk_update = params[:bulk_update]
      bulk_update.respond_to?(:key?) && bulk_update.key?(:tag_ids)
    end
end
