class DS::CategorySelect < DesignSystemComponent
  CLASSIFICATIONS = %w[income expense].freeze

  attr_reader :form, :categories, :selected_id, :disabled, :auto_submit, :blank_label,
              :classification, :recent_categories, :creatable, :label

  # categories:        the categories to list, already narrowed to the form's
  #                    classification where the form has one (a subcategory is
  #                    listed under its parent).
  # classification:    "income" or "expense". A category created inline gets
  #                    it (a subcategory always takes its parent's instead), and
  #                    only parents of this classification are offered.
  # recent_categories: shown in a "Recent" group above the list until the user
  #                    types a search.
  # creatable:         false hides inline create, e.g. on bulk edit where the
  #                    selected transactions can be of either nature.
  def initialize(
    form:,
    categories:,
    selected_id: nil,
    selected_category: nil,
    disabled: false,
    auto_submit: false,
    blank_label: nil,
    classification: "expense",
    recent_categories: [],
    creatable: true,
    label: nil
  )
    @form = form
    @categories = categories
    @selected_id = selected_id&.to_s
    @selected_category = selected_category
    @disabled = disabled
    @auto_submit = auto_submit
    @blank_label = blank_label
    @classification = CLASSIFICATIONS.include?(classification.to_s) ? classification.to_s : "expense"
    @recent_categories = Array(recent_categories)
    @creatable = creatable
    @label = label
  end

  # A category shown as the selection without being one of `categories`,
  # e.g. a virtual or read-only category on a disabled select.
  def selected_category
    @selected_category || categories.find { |category| category.id.to_s == selected_id }
  end

  def field_name
    "#{form.object_name}[category_id]"
  end

  def field_id
    form.field_id(:category_id)
  end

  # Scoped by the form, so two pickers on one page (the new-transaction modal
  # over a page with the edit drawer) don't share an id.
  def trigger_id
    form.field_id(:category_id, :trigger)
  end

  def menu_id
    "#{field_id}_menu"
  end

  def parent_label_id
    "#{menu_id}_parent_label"
  end

  def label_text
    label || helpers.t("ds.category_select.label")
  end

  def groups
    Category::Group.for(categories)
  end

  # Only top-level categories of the form's classification can be parents
  # (categories are two levels deep and a subcategory shares its parent's
  # classification).
  def parent_options
    categories
      .select { |category| category.parent_id.nil? && category.classification == classification }
      .sort_by { |category| category.name.downcase }
  end
end
