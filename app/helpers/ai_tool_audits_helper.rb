module AiToolAuditsHelper
  # Paths to the records a page of audits touched, keyed by [record_type, id], looked up in one query per type and
  # scoped to the family. A record that is gone (deleted by the call, or later) has no path, and the page shows its
  # id as text. Types without a page of their own are left out.
  def ai_tool_audit_record_paths(audits, family: Current.family)
    ids_by_type = Hash.new { |hash, type| hash[type] = [] }
    audits.each do |audit|
      ids_by_type[audit.result_record_type].concat(audit.result_record_ids) if audit.result_record_type.present?
    end

    ids_by_type.each_with_object({}) do |(type, ids), paths|
      ids = ids.uniq

      case type
      when "Transaction"
        family.entries.where(entryable_type: "Transaction", entryable_id: ids).each do |entry|
          paths[[ type, entry.entryable_id.to_s ]] = entry_path(entry)
        end
      when "Account"
        family.accounts.where(id: ids).pluck(:id).each { |id| paths[[ type, id.to_s ]] = account_path(id) }
      when "Category"
        family.categories.where(id: ids).pluck(:id).each { |id| paths[[ type, id.to_s ]] = edit_category_path(id) }
      when "Tag"
        family.tags.where(id: ids).pluck(:id).each { |id| paths[[ type, id.to_s ]] = edit_tag_path(id) }
      when "Rule"
        family.rules.where(id: ids).pluck(:id).each { |id| paths[[ type, id.to_s ]] = edit_rule_path(id) }
      when "Import"
        family.imports.where(id: ids).pluck(:id).each { |id| paths[[ type, id.to_s ]] = import_path(id) }
      end
    end
  end

  # Pretty JSON for the arguments and before columns
  def ai_tool_audit_json(value)
    return if value.blank?

    JSON.pretty_generate(value)
  end

  def ai_tool_audit_status_classes(status)
    case status
    when "ok" then "text-success"
    when "error", "interrupted" then "text-destructive"
    else "text-secondary"
    end
  end
end
