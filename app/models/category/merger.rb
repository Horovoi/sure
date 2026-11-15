# Merges source categories into a target category of the same family and
# classification. Everything that points at a source moves to the target, then
# the source is deleted. It all happens in one database transaction, so a
# failure leaves every category as it was.
#
# What moves: transactions, budget lines (amounts summed when the target already
# has a line in that budget), subcategories, recurring transactions, the
# category an import restores on revert, import category mappings, and rule
# action and condition values.
#
# merge! returns the ids of the deleted source categories (empty when nothing
# was merged), so a caller such as the tool audit log can name them.
class Category::Merger
  class Error < StandardError; end
  class UnauthorizedCategoryError < Error; end
  class ClassificationMismatchError < Error; end
  class HierarchyError < Error; end

  CATEGORY_ACTION_TYPES = %w[set_transaction_category].freeze
  CATEGORY_CONDITION_TYPES = %w[transaction_category].freeze
  TOUCH_BATCH_SIZE = 1_000

  attr_reader :family, :target_category, :source_categories, :merged_category_ids

  def initialize(family:, target_category:, source_categories:)
    @family = family
    @target_category = target_category
    @merged_category_ids = []

    validate_belongs_to_family!(target_category)

    sources = Array(source_categories).compact.uniq(&:id)
    sources.each { |category| validate_belongs_to_family!(category) }

    @source_categories = sources.reject { |category| category.id == target_category.id }
    validate_classification!
    validate_hierarchy!
    validate_reparenting!
  end

  def merged_count
    merged_category_ids.size
  end

  def merge!
    return [] if source_categories.empty?

    Category.transaction do
      source_categories.each { |source| merge_source!(source) }
      update_target_last_used_at!
    end

    merged_category_ids
  end

  private
    def merge_source!(source)
      move_transactions(source)
      merge_budget_categories(source)
      move_subcategories(source)
      move_recurring_transactions(source)
      move_import_references(source)
      move_rule_values(source)

      # Re-read: the source may have been reparented under the target earlier in this merge
      family.categories.find(source.id).destroy!
      @merged_category_ids << source.id
    end

    # update_all skips the entry touch a normal save does, and the report and
    # transaction list caches key on entries' updated_at, so touch the entries here.
    def move_transactions(source)
      ids = Transaction
        .joins(entry: :account)
        .where(accounts: { family_id: family.id }, category_id: source.id)
        .lock("FOR UPDATE OF transactions")
        .pluck(:id)

      ids.each_slice(TOUCH_BATCH_SIZE) do |batch|
        Transaction.where(id: batch).update_all(category_id: target_category.id, updated_at: Time.current)
        Entry.where(entryable_type: "Transaction", entryable_id: batch).touch_all
      end
    end

    # One budget line per budget and category. Every budget column that adds up
    # is summed here, so a new one (rollover amounts) only needs a line in this method.
    def merge_budget_categories(source)
      family.budget_categories.where(category_id: source.id).find_each do |source_line|
        target_line = family.budget_categories.find_by(budget_id: source_line.budget_id, category_id: target_category.id)

        if target_line
          target_line.update!(
            budgeted_spending: target_line.budgeted_spending.to_d + source_line.budgeted_spending.to_d
          )
          source_line.destroy!
        else
          source_line.update!(category_id: target_category.id)
        end
      end
    end

    # A subcategory takes its parent's colour, so the moved ones take the target's.
    def move_subcategories(source)
      family.categories
        .where(parent_id: source.id)
        .where.not(id: target_category.id)
        .update_all(parent_id: target_category.id, color: target_category.color, updated_at: Time.current)
    end

    def move_recurring_transactions(source)
      family.recurring_transactions
        .where(category_id: source.id)
        .update_all(category_id: target_category.id, updated_at: Time.current)
    end

    # The category a revert gives back to a claimed entry, and the category
    # chosen for a value in an import's category mapping (the source's
    # destroy would delete that mapping otherwise).
    def move_import_references(source)
      family_import_ids = Import.where(family_id: family.id).select(:id)

      Import::ClaimedEntry
        .where(import_id: family_import_ids, previous_category_id: source.id)
        .update_all(previous_category_id: target_category.id, updated_at: Time.current)

      Import::Mapping
        .where(import_id: family_import_ids, mappable_type: "Category", mappable_id: source.id)
        .update_all(mappable_id: target_category.id, updated_at: Time.current)
    end

    # Rule values store category ids as strings. A condition inside a group has
    # no rule_id, so it is found through its parent.
    def move_rule_values(source)
      rule_ids = family.rules.select(:id)

      Rule::Action
        .where(rule_id: rule_ids, action_type: CATEGORY_ACTION_TYPES, value: source.id.to_s)
        .update_all(value: target_category.id.to_s, updated_at: Time.current)

      top_level_condition_ids = Rule::Condition.where(rule_id: rule_ids).select(:id)
      category_conditions = Rule::Condition.where(condition_type: CATEGORY_CONDITION_TYPES, value: source.id.to_s)
      category_conditions
        .where(rule_id: rule_ids)
        .or(category_conditions.where(parent_id: top_level_condition_ids))
        .update_all(value: target_category.id.to_s, updated_at: Time.current)
    end

    # The target was picked by hand as recently as any of the sources.
    def update_target_last_used_at!
      latest = [ target_category.last_used_at, *source_categories.map(&:last_used_at) ].compact.max
      return if latest.nil? || latest == target_category.last_used_at

      target_category.update_column(:last_used_at, latest)
    end

    def validate_belongs_to_family!(category)
      return if category.is_a?(Category) && category.persisted? && category.family_id == family.id

      raise UnauthorizedCategoryError, I18n.t("models.category.merger.errors.not_in_family")
    end

    # An income category merged into an expense one would turn its income into spending.
    def validate_classification!
      mismatched = source_categories.reject { |source| source.classification == target_category.classification }
      return if mismatched.empty?

      raise ClassificationMismatchError, I18n.t(
        "models.category.merger.errors.classification_mismatch",
        names: mismatched.map(&:name).to_sentence,
        target: target_category.name
      )
    end

    def validate_hierarchy!
      return unless target_category.parent_id.present? && source_categories.any? { |source| source.id == target_category.parent_id }

      raise HierarchyError, I18n.t("models.category.merger.errors.parent_into_subcategory")
    end

    # Categories are two levels deep, so a subcategory can't take in subcategories.
    def validate_reparenting!
      return if target_category.parent_id.blank?
      return unless family.categories.where(parent_id: source_categories.map(&:id)).where.not(id: target_category.id).exists?

      raise HierarchyError, I18n.t("models.category.merger.errors.subcategories_into_subcategory")
    end
end
