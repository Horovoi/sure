module EntryableResource
  extend ActiveSupport::Concern

  included do
    include StreamExtensions, ActionView::RecordIdentifier

    before_action :set_entry, only: %i[show update destroy]
  end

  def show
  end

  def new
    account = Current.family.accounts.find_by(id: params[:account_id])

    @entry = Current.family.entries.new(
      account: account,
      currency: account ? account.currency : Current.family.currency,
      entryable: entryable
    )
  end

  def create
    raise NotImplementedError, "Entryable resources must implement #create"
  end

  def update
    raise NotImplementedError, "Entryable resources must implement #update"
  end

  def destroy
    account = @entry.account

    # An opening balance refuses to be deleted on its own (Entry#ensure_anchor_destroyable)
    unless @entry.destroy
      redirect_back_or_to account_path(account), alert: @entry.errors.full_messages.to_sentence
      return
    end

    @entry.sync_account_later

    # Back to where the user was, unless that was this entry's own page, which is gone
    redirect_to referer_unless(url_for(action: :show, id: @entry.id, only_path: true)) || account_path(account),
                notice: t("entries.destroy.success")
  end

  private
    def entryable
      controller_name.classify.constantize.new
    end

    def set_entry
      @entry = Current.family.entries.find(params[:id])
    end
end
