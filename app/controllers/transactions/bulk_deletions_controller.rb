class Transactions::BulkDeletionsController < ApplicationController
  def create
    # destroy_by returns every record it tried; an opening balance refuses to be deleted
    destroyed = Current.family.entries.destroy_by(id: bulk_delete_params[:entry_ids]).select(&:destroyed?)
    destroyed.map(&:account).uniq.each(&:sync_later)
    redirect_back_or_to transactions_url, notice: "#{destroyed.count} transaction#{destroyed.count == 1 ? "" : "s"} deleted"
  end

  private
    def bulk_delete_params
      params.require(:bulk_delete).permit(entry_ids: [])
    end
end
