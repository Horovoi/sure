# The categorize wizard: one group of uncategorized transactions at a time (Transaction::Grouper),
# a category for the group or for single rows, and an optional rule for the group's future
# transactions. A category set here is a user edit: Entry.bulk_update! locks it and marks the
# entry user-modified, as the bulk edit does.
class Transactions::CategorizesController < ApplicationController
  # A preview lists at most this many rows, so a short filter cannot render the whole history
  PREVIEW_LIMIT = 200

  def show
    @breadcrumbs = [
      [ t(".breadcrumb_home"), root_path ],
      [ t(".breadcrumb_transactions"), transactions_path ],
      [ t(".breadcrumb_categorize"), nil ]
    ]
    @position = [ params[:position].to_i, 0 ].max
    @group = Transaction::Grouper.strategy.call(family_entries, limit: 1, offset: @position).first
    @total_uncategorized = uncategorized_count

    if @group.nil?
      # Past the last group with some left: the user skipped them, so do not say "all done"
      notice = @total_uncategorized.positive? ? t(".skipped_rest", count: @total_uncategorized) : t(".all_done")
      redirect_to transactions_path, notice: notice and return
    end

    @categories = categories_for(@group.transaction_type)
    @recent_categories = Category.recently_used_for(family: Current.family, classification: @group.transaction_type)
  end

  def create
    attrs = create_params
    @position = [ attrs[:position].to_i, 0 ].max
    entry_ids = Array(attrs[:entry_ids]).compact_blank
    remaining_ids = Array(attrs[:all_entry_ids]).compact_blank - entry_ids

    category = Current.family.categories.find(attrs[:category_id])
    # Only rows that are still uncategorized: a stale page never overwrites a category set meanwhile.
    # The ids are read first: bulk_update! counts its relation again after the update, and
    # an uncategorized filter would then count nothing.
    ids = family_entries.uncategorized_transactions.where(id: entry_ids).pluck(:id)
    count = ids.empty? ? 0 : family_entries.where(id: ids).bulk_update!({ category_id: category.id })
    flash[:notice] = t(".categorized", count: count, category: category.name)

    create_rule_for(category, attrs) if attrs[:create_rule] == "1" && (count.positive? || entry_ids.empty?)

    respond_to do |format|
      format.turbo_stream { render turbo_stream: after_assignment_streams(entry_ids, remaining_ids) }
      format.html { redirect_to transactions_categorize_path(position: @position) }
    end
  end

  def assign_entry
    attrs = assign_entry_params
    @position = [ attrs[:position].to_i, 0 ].max
    entry = family_entries.uncategorized_transactions.find(attrs[:entry_id])
    category = Current.family.categories.find(attrs[:category_id])
    remaining_ids = Array(attrs[:all_entry_ids]).compact_blank - [ entry.id.to_s ]

    family_entries.where(id: entry.id).bulk_update!({ category_id: category.id })

    render turbo_stream: after_assignment_streams([ entry.id.to_s ], remaining_ids)
  end

  # The uncategorized transactions a "name contains" rule with this text would catch now.
  # They replace the group's list, so a pick then categorizes what the rule matches.
  def preview_rule
    filter = params[:filter].to_s
    transaction_type = params[:transaction_type].presence_in(%w[income expense])
    entries = Entry.uncategorized_matching(family_entries, filter, transaction_type).limit(PREVIEW_LIMIT).to_a
    categories = categories_for(transaction_type || "expense")
    display_name = filter.gsub(/[[:space:]]+/, " ").strip.presence || "…"

    render turbo_stream: [
      turbo_stream.replace("categorize_group_title",
        partial: "transactions/categorizes/group_title",
        locals: { display_name: display_name, transaction_type: transaction_type }),
      turbo_stream.replace("categorize_group_summary",
        partial: "transactions/categorizes/group_summary",
        locals: { entries: entries }),
      turbo_stream.replace("categorize_transaction_list",
        partial: "transactions/categorizes/transaction_list",
        locals: { entries: entries, categories: categories })
    ]
  end

  private
    def family_entries
      Current.family.entries
    end

    def uncategorized_count
      family_entries.uncategorized_transactions.count
    end

    def categories_for(classification)
      Current.family.categories.where(classification: classification).alphabetically.to_a
    end

    def create_params
      params.expect(categorize: [ :category_id, :position, :transaction_type, :merchant_id, :grouping_key, :create_rule,
                                  entry_ids: [], all_entry_ids: [] ])
    end

    def assign_entry_params
      params.expect(categorize: [ :entry_id, :category_id, :position, all_entry_ids: [] ])
    end

    def create_rule_for(category, attrs)
      merchant = Current.family.available_merchants.find_by(id: attrs[:merchant_id]) if attrs[:merchant_id].present?
      rule = Rule.build_for_categorize_group(
        Current.family,
        category: category,
        transaction_type: attrs[:transaction_type],
        merchant: merchant,
        name_filter: attrs[:grouping_key]
      )

      if rule.save
        flash[:notice] = [ flash[:notice], t(".rule_created", name: rule.name) ].compact.join(" ")
      else
        flash[:alert] = t(".rule_creation_failed", errors: rule.errors.full_messages.to_sentence)
      end
    end

    # Removes the categorized rows. When none of the group is left, the wizard moves on to the
    # group now at the same position (the categorized one has left the list).
    def after_assignment_streams(categorized_ids, remaining_ids)
      remaining_entries = remaining_ids.empty? ? [] : family_entries.uncategorized_transactions.where(id: remaining_ids)
                                                                   .includes(entryable: :merchant).to_a

      if remaining_entries.empty?
        # The flash set by this request shows on the page the redirect opens
        return [ turbo_stream.action(:redirect, transactions_categorize_path(position: @position)) ]
      end

      streams = categorized_ids.map { |id| turbo_stream.remove("categorize_entry_#{id}") }
      # A row categorized elsewhere since the page loaded leaves too
      (remaining_ids - remaining_entries.map { |entry| entry.id.to_s }).each do |id|
        streams << turbo_stream.remove("categorize_entry_#{id}")
      end
      streams << turbo_stream.replace("categorize_remaining",
        partial: "transactions/categorizes/remaining_count",
        locals: { total_uncategorized: uncategorized_count })
      streams << turbo_stream.replace("categorize_group_summary",
        partial: "transactions/categorizes/group_summary",
        locals: { entries: remaining_entries })
      streams.concat(flash_notification_stream_items)
    end
end
