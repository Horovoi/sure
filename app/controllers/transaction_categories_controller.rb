class TransactionCategoriesController < ApplicationController
  include ActionView::RecordIdentifier
  include CategoryRulePrompt

  def update
    @entry = Current.family.entries.transactions.find(params[:transaction_id])
    # w2-transfers transfer-form-fixes: a confirmed transfer's category belongs to its
    # outflow leg (Transaction#category_editable?); the other legs show it read-only.
    return head(:unprocessable_entity) unless @entry.transaction.category_editable?

    @entry.update!(entry_params)

    transaction = @entry.transaction
    transaction.record_category_usage!

    if needs_rule_notification?(transaction)
      flash[:cta] = {
        type: "category_rule",
        category_id: transaction.category_id,
        category_name: transaction.category.name,
        merchant_name: @entry.name
      }
    end

    transaction.lock_saved_attributes!
    @entry.lock_saved_attributes!

    respond_to do |format|
      format.html { redirect_back_or_to transaction_path(@entry) }
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            dom_id(transaction, "category_menu_mobile"),
            partial: "transactions/transaction_category",
            locals: { transaction: transaction, variant: "mobile" }
          ),
          turbo_stream.replace(
            dom_id(transaction, "category_menu_desktop"),
            partial: "transactions/transaction_category",
            locals: { transaction: transaction, variant: "desktop" }
          ),
          turbo_stream.replace(
            "category_name_mobile_#{transaction.id}",
            partial: "categories/category_name_mobile",
            locals: { transaction: transaction }
          ),
          *flash_notification_stream_items
        ]
      end
    end
  end

  private
    def entry_params
      params.expect(entry: [ :entryable_type, entryable_attributes: [ :id, :category_id ] ])
    end
end
