class Transactions::BulkDeletionsController < ApplicationController
  def create
    # destroy_by returns every record it tried. Some refuse to go (an opening balance, a
    # part of a split); one that went with its split parent is gone all the same.
    tried = Current.family.entries.destroy_by(id: bulk_delete_params[:entry_ids])
    destroyed, refused = tried.partition(&:destroyed?)
    refused.select! { |entry| Entry.exists?(entry.id) }

    destroyed.map(&:account).uniq.each(&:sync_later)
    redirect_back_or_to transactions_url, notice: notice_for(destroyed, refused)
  end

  private
    def bulk_delete_params
      params.expect(bulk_delete: [ entry_ids: [] ])
    end

    # "2 transactions deleted", and when some were kept, why
    def notice_for(destroyed, refused)
      notice = t(".deleted", count: destroyed.size)
      return notice if refused.empty?

      reasons = refused.flat_map { |entry| entry.errors.full_messages }.uniq.to_sentence
      "#{notice}. #{t(".kept", count: refused.size, reasons: reasons)}"
    end
end
