# Renames or recolors a category, or changes its icon, as the Edit category form does. Hand port of upstream
# 974f1d8e4. A category is never deleted here: the category merge flow in Settings covers that.
class Assistant::Function::UpdateCategory < Assistant::Function
  include Assistant::Function::CategoryWriting

  scope_tag :write

  class << self
    def name
      "update_category"
    end

    def description
      <<~INSTRUCTIONS
        Changes a category's name, color or icon. Find the id with
        get_categories; pass at least one of name, color or icon.

        A subcategory always shows its parent's color, so a color change on a
        subcategory has no effect; recolor the parent instead. Changing a
        parent's color applies to its subcategories when they are next saved.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: { type: "string", description: "Category id from get_categories" },
        name: { type: "string", description: "New name, unique in the family" },
        color: { type: "string", description: "New hex color such as #e99537" },
        icon: { type: "string", description: "New Lucide icon name" }
      }
    )
  end

  def record_type
    "Category"
  end

  def idempotent?
    true
  end

  def audit_before(params)
    category = find_category(params["id"])
    category && category_snapshot(category)
  end

  def call(params = {})
    category = find_category(params["id"])
    return tool_error("not_found", "Use a category id from get_categories.") unless category

    attributes = {}

    if params["name"].present?
      attributes[:name] = params["name"].to_s.squish
    end

    if params["color"].present?
      return tool_error("invalid_color", "color must be a hex code such as #e99537.") unless valid_color?(params["color"])

      attributes[:color] = params["color"]
    end

    if params["icon"].present?
      return tool_error("invalid_icon", icon_hint) unless valid_icon?(params["icon"])

      attributes[:lucide_icon] = params["icon"]
    end

    return tool_error("no_changes", "Pass at least one of name, color or icon.") if attributes.empty?

    category.update!(attributes)

    { id: category.id, updated: true, category: category_snapshot(category) }
  end

  private
    def find_category(id)
      valid_uuid?(id) ? family.categories.find_by(id: id) : nil
    end
end
