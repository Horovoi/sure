# Shared by create_category and update_category: checking a color and an icon, and the shape both return and
# the audit keeps.
module Assistant::Function::CategoryWriting
  HEX_COLOR = /\A#\h{6}\z/
  CLASSIFICATIONS = %w[expense income].freeze

  private
    def valid_color?(value)
      HEX_COLOR.match?(value.to_s)
    end

    def valid_icon?(value)
      Category.icon_codes.include?(value.to_s)
    end

    def icon_hint
      "icon must be one of: #{Category.icon_codes.join(", ")}."
    end

    def category_snapshot(category)
      {
        id: category.id,
        name: category.name,
        name_with_parent: category.name_with_parent,
        classification: category.classification,
        color: category.color,
        icon: category.lucide_icon,
        parent_id: category.parent_id
      }
    end
end
