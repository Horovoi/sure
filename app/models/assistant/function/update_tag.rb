# Renames or recolors a tag. Hand port of upstream 974f1d8e4, except that the tag is named by its id from get_tags
# (or its exact current name) rather than an enum of the family's tag names, which changed the tool definition
# whenever a tag did.
class Assistant::Function::UpdateTag < Assistant::Function
  scope_tag :write

  HEX_COLOR = /\A#\h{6}\z/

  class << self
    def name
      "update_tag"
    end

    def description
      <<~INSTRUCTIONS
        Renames a tag or changes its color. Name the tag by its id from get_tags
        (or its exact current name), and pass at least one of new_name or color.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        id: { type: "string", description: "Tag id from get_tags" },
        name: { type: "string", description: "The tag's exact current name, when you have no id" },
        new_name: { type: "string", description: "New name, unique in the family" },
        color: { type: "string", description: "New hex color such as #e99537" }
      }
    )
  end

  def record_type
    "Tag"
  end

  def idempotent?
    true
  end

  def audit_before(params)
    tag = find_tag(params)
    tag && { id: tag.id, name: tag.name, color: tag.color }
  end

  def call(params = {})
    tag = find_tag(params)
    return tool_error("not_found", "Name the tag by an id (or exact name) from get_tags.") unless tag

    attributes = {}
    attributes[:name] = params["new_name"].to_s.squish if params["new_name"].present?

    if params["color"].present?
      return tool_error("invalid_color", "color must be a hex code such as #e99537.") unless HEX_COLOR.match?(params["color"])

      attributes[:color] = params["color"]
    end

    return tool_error("no_changes", "Pass at least one of new_name or color.") if attributes.empty?

    tag.update!(attributes)

    { id: tag.id, updated: true, tag: { id: tag.id, name: tag.name, color: tag.color } }
  end

  private
    def find_tag(params)
      if params["id"].present?
        valid_uuid?(params["id"]) ? family.tags.find_by(id: params["id"]) : nil
      elsif params["name"].present?
        family.tags.find_by(name: params["name"].to_s.squish)
      end
    end
end
