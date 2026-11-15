# The tag picker of a transaction row: a searchable list that toggles one tag
# per click (TransactionsController#update_tags) without closing.
class Tag::DropdownsController < ApplicationController
  def show
    @entry = Current.family.entries.transactions.find(params[:entry_id])
    @transaction = @entry.transaction
    @tags = Current.family.tags.alphabetically
    @selected_tag_ids = @transaction.tag_ids.to_set
  end
end
