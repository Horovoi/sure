# Receipts and invoices on a transaction (the Attachments section of its drawer).
# The transaction is looked up through Current.family, and the file is served through
# the Active Storage blob route, which checks the family again
# (config/initializers/active_storage_authorization.rb).
class TransactionAttachmentsController < ApplicationController
  before_action :set_transaction
  before_action :set_attachment, only: %i[show destroy]

  def show
    disposition = params[:disposition] == "attachment" ? "attachment" : "inline"
    redirect_to rails_blob_path(@attachment, disposition: disposition)
  end

  def create
    files = uploaded_files
    return respond_with_flash(:alert, t(".no_files_selected")) if files.empty?

    alert = nil
    @transaction.with_lock do
      if @transaction.attachments.count + files.size > Transaction::MAX_ATTACHMENTS_PER_TRANSACTION
        alert = t(".too_many", count: Transaction::MAX_ATTACHMENTS_PER_TRANSACTION)
      elsif !@transaction.attachments.attach(files)
        alert = t(".failed", error: attachment_errors.to_sentence)
      end
    end

    if alert
      # A failed save leaves the rejected files in memory; reload so the list shows the saved ones only
      @transaction.reload
      respond_with_flash(:alert, alert)
    else
      respond_with_flash(:notice, t(".uploaded", count: files.size))
    end
  end

  def destroy
    @attachment.purge_later
    @transaction.attachments.reset
    respond_with_flash(:notice, t(".deleted"))
  end

  private
    def set_transaction
      @transaction = Current.family.transactions.find(params[:transaction_id])
    end

    def set_attachment
      @attachment = @transaction.attachments.find(params[:id])
    end

    # Only real uploads. A string would be read as the signed id of an existing blob,
    # which would let a user attach (and then read) a blob that is not theirs.
    def uploaded_files
      files = params.slice(:attachments, :attachment).values.flat_map { |value| Array(value) }
      files.grep(ActionDispatch::Http::UploadedFile)
    end

    # The file errors without the attribute name ("receipt.txt has a type ..."), or any
    # other error that stopped the save
    def attachment_errors
      @transaction.errors.where(:attachments).map(&:message).presence || @transaction.errors.full_messages
    end

    def respond_with_flash(type, message)
      respond_to do |format|
        format.turbo_stream do
          flash.now[type] = message
          render :refresh
        end
        format.html { redirect_back_or_to transaction_path(@transaction.entry), type => message }
      end
    end
end
