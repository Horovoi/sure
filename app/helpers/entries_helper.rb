module EntriesHelper
  def entries_by_date(entries, totals: false)
    transfer_groups = entries.group_by do |entry|
      # Only check for transfer if it's a transaction
      next nil unless entry.entryable_type == "Transaction"
      entry.entryable.transfer&.id
    end

    # For a more intuitive UX, we do not want to show the same transfer twice in the list
    deduped_entries = transfer_groups.flat_map do |transfer_id, grouped_entries|
      if transfer_id.nil? || grouped_entries.size == 1
        grouped_entries
      else
        grouped_entries.reject do |e|
          e.entryable_type == "Transaction" &&
          e.entryable.transfer_as_inflow.present?
        end
      end
    end

    deduped_entries.group_by(&:date).sort.reverse_each.map do |date, grouped_entries|
      content = capture do
        yield grouped_entries
      end

      next if content.blank?

      render partial: "entries/entry_group", locals: { date:, entries: grouped_entries, content:, totals: }
    end.compact.join.html_safe
  end

  # A split transaction's parts in a list, under their parent (Entry::Splittable)
  SplitGroup = Struct.new(:parent, :children)

  # The rows of one list section: entries as they are, except that the parts of a split
  # are gathered under their parent, at the place of the first part. The parent is read
  # from entry.parent_entry, so preload it.
  def group_split_entries(entries)
    groups = {}

    entries.each_with_object([]) do |entry, items|
      parent = entry.parent_entry_id && entry.parent_entry

      if parent.nil?
        items << entry
      elsif (group = groups[parent.id])
        group.children << entry
      else
        group = groups[parent.id] = SplitGroup.new(parent, [ entry ])
        items << group
      end
    end
  end

  # Renders the rows of one list section, splits as a group (transactions/_split_group)
  def render_entry_rows(entries, **locals)
    safe_join(group_split_entries(entries).map do |item|
      if item.is_a?(SplitGroup)
        render("transactions/split_group", group: item, **locals)
      else
        render(item, **locals)
      end
    end)
  end

  def entry_name_detailed(entry)
    [
      entry.date,
      format_money(entry.amount_money),
      entry.account.name,
      entry.name
    ].join(" • ")
  end
end
