# Creates a category as the New category form does. Names are unique in a family, so creating a name that exists
# returns that category with created: false, which also makes a retry safe. Hand port of upstream 974f1d8e4 with the
# fork's income/expense classification and its icon list.
class Assistant::Function::CreateCategory < Assistant::Function
  include Assistant::Function::CategoryWriting

  scope_tag :write

  class << self
    def name
      "create_category"
    end

    def description
      <<~INSTRUCTIONS
        Creates a category for the family's transactions.

        Categories have two levels: pass parent_id (a top-level category from
        get_categories) to make a subcategory, which takes its parent's color
        and classification. classification is "expense" (default) or "income".
        color is a hex code such as #e99537 (a palette color if omitted); icon
        is a Lucide icon name from the app's list ("layers" if omitted).

        Category names are unique in the family: if the name exists, the
        existing category comes back with created: false and nothing changes.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "name" ],
      properties: {
        name: { type: "string", description: "Category name, unique in the family" },
        classification: { type: "string", enum: CLASSIFICATIONS, description: "expense (default) or income" },
        parent_id: { type: "string", description: "Top-level category id from get_categories, to make a subcategory" },
        color: { type: "string", description: "Hex color such as #e99537; ignored for a subcategory" },
        icon: { type: "string", description: "Lucide icon name, such as shopping-cart or utensils" }
      }
    )
  end

  def record_type
    "Category"
  end

  def call(params = {})
    name = params["name"].to_s.squish
    return tool_error("invalid_name", "name is required.") if name.empty?

    if (existing = family.categories.find_by(name: name))
      return { id: existing.id, created: false, category: category_snapshot(existing) }
    end

    attributes = { name: name, classification: params["classification"].presence || "expense" }
    return tool_error("invalid_classification", "classification must be expense or income.") unless CLASSIFICATIONS.include?(attributes[:classification])

    if params["parent_id"].present?
      parent = valid_uuid?(params["parent_id"]) && family.categories.find_by(id: params["parent_id"])
      return tool_error("parent_not_found", "parent_id must be a category id from get_categories.") unless parent
      return tool_error("parent_is_subcategory", "Categories have two levels; pick a top-level category as the parent.") if parent.subcategory?

      attributes[:parent] = parent
      attributes[:classification] = parent.classification
    end

    color = params["color"].presence || Category::COLORS.sample
    return tool_error("invalid_color", "color must be a hex code such as #e99537.") unless valid_color?(color)

    icon = params["icon"].presence || "layers"
    return tool_error("invalid_icon", icon_hint) unless valid_icon?(icon)

    # The shared create path: a same-name category created in between comes back as it is
    category = family.categories.find_or_create_by_name!(name) do |new_category|
      new_category.assign_attributes(attributes.except(:name).merge(color: color, lucide_icon: icon))
    end

    { id: category.id, created: category.previously_new_record?, category: category_snapshot(category) }
  end
end
