# The split editor of a transaction (Entry::Splittable), by entry id like the drawer.
# Amounts in the form are in the transaction's own direction: for a purchase of 100 the
# parts are 60 and 40; a part the other way (a refund inside the purchase) is negative.
class SplitsController < ApplicationController
  include StreamExtensions

  # One row of the editor, for the form builder
  Part = Struct.new(:id, :name, :amount, :category_id, :merchant_id, :tag_ids, :notes, :excluded, keyword_init: true) do
    def self.from(hash)
      new(**hash.to_h.symbolize_keys.slice(*members))
    end
  end

  before_action :set_entry
  before_action :resolve_to_parent, only: %i[edit update destroy]
  before_action :set_form_options, only: %i[new create edit update]

  def new
    unless @entry.splittable?
      redirect_back_or_to transactions_path, alert: @entry.split_blocker && t("activerecord.errors.models.entry_split_blockers.#{@entry.split_blocker}")
      return
    end

    @parts = default_parts
  end

  def create
    @entry.split!(parts_from_params)
    finish(t(".success"))
  rescue Entry::Splittable::NotSplittable => e
    redirect_back_or_to transactions_path, alert: e.message
  rescue ActiveRecord::RecordInvalid => e
    show_form_again(:new, e)
  end

  def edit
    return not_split unless @entry.split_parent?

    @parts = @entry.child_entries.includes(entryable: :tags).map { |child| part_from_child(child) }
  end

  def update
    @entry.resplit!(parts_from_params)
    finish(t(".success"))
  rescue Entry::Splittable::NotSplittable
    not_split
  rescue ActiveRecord::RecordInvalid => e
    show_form_again(:edit, e)
  end

  def destroy
    @entry.unsplit!
    finish(t(".success"))
  rescue Entry::Splittable::NotSplittable
    not_split
  end

  private
    def set_entry
      @entry = Current.family.entries.find(params[:transaction_id])
    end

    # The editor of a part is its parent's editor
    def resolve_to_parent
      @entry = @entry.parent_entry if @entry.split_child?
    end

    def set_form_options
      @categories = Current.family.categories.alphabetically_by_hierarchy.to_a
      @merchants = Current.family.available_merchants.alphabetically.to_a
      @tags = Current.family.tags.alphabetically.to_a
    end

    def finish(notice)
      @entry.sync_account_later

      # Back to the page the editor was opened over; from the editor's own URL (opened
      # on its own, not from the drawer) to the transactions list instead of the editor
      editor_paths = [ @entry.id, params[:transaction_id] ].uniq.flat_map do |id|
        [ new_transaction_split_path(id), edit_transaction_split_path(id) ]
      end
      target = referer_unless(*editor_paths) || transactions_path
      respond_to do |format|
        format.html { redirect_to target, notice: notice }
        format.turbo_stream { stream_redirect_to(target, notice: notice) }
      end
    end

    def not_split
      redirect_back_or_to transactions_path, alert: t("activerecord.errors.models.entry_split_blockers.not_split")
    end

    def show_form_again(template, error)
      @parts = submitted_parts
      @error = error.record.errors.full_messages.to_sentence
      render template, status: :unprocessable_entity
    end

    # Two parts to start from: the whole amount with the transaction's category and an
    # empty one, so the remaining amount reads 0 until the user moves money across
    def default_parts
      [
        { name: @entry.name, amount: @entry.amount.abs, category_id: @entry.transaction.category_id, merchant_id: @entry.transaction.merchant_id, tag_ids: @entry.transaction.tag_ids },
        { name: "", amount: nil, category_id: nil, merchant_id: @entry.transaction.merchant_id, tag_ids: [] }
      ]
    end

    def part_from_child(child)
      {
        id: child.id,
        name: child.name,
        amount: child.amount * direction,
        category_id: child.transaction.category_id,
        merchant_id: child.transaction.merchant_id,
        tag_ids: child.transaction.tag_ids,
        notes: child.notes,
        excluded: child.excluded?
      }
    end

    # +1 when a positive form amount is an outflow (the transaction is an expense)
    def direction
      @entry.amount.negative? ? -1 : 1
    end

    # The form sends parts[0], parts[1], ... in the order the editor shows them (the
    # numbers have gaps once a part is removed); a JSON client may send a list
    def raw_parts
      parts = params.expect(split: [ parts: [ [ :id, :name, :amount, :category_id, :merchant_id, :notes, :excluded, tag_ids: [] ] ] ])
                    .fetch(:parts, [])
      parts = parts.values if parts.is_a?(ActionController::Parameters)
      parts.map { |part| part.to_h.symbolize_keys }
    end

    # The form's parts as Entry::Splittable takes them: signed like Entry#amount, and the
    # category, merchant and tags limited to this family's
    def parts_from_params
      category_ids = @categories.map(&:id).to_set
      merchant_ids = @merchants.map(&:id).to_set
      tag_ids = @tags.map(&:id).to_set

      raw_parts.map do |part|
        amount = parse_amount(part[:amount])

        {
          id: part[:id].presence,
          name: part[:name],
          amount: amount && amount * direction,
          category_id: part[:category_id].presence_in(category_ids),
          merchant_id: part[:merchant_id].presence_in(merchant_ids),
          tag_ids: Array(part[:tag_ids]).select { |id| tag_ids.include?(id) },
          notes: part[:notes],
          excluded: part[:excluded]
        }
      end
    end

    # What the user typed, to show the form again after a refused save
    def submitted_parts
      raw_parts.map do |part|
        part.merge(amount: parse_amount(part[:amount]), excluded: ActiveModel::Type::Boolean.new.cast(part[:excluded]), tag_ids: Array(part[:tag_ids]))
      end
    end

    def parse_amount(value)
      text = value.to_s.strip.delete(" ").tr(",", ".")
      return nil if text.empty?

      BigDecimal(text)
    rescue ArgumentError
      nil
    end
end
