# Creates a tag as the New tag form does. Tag names are unique in a family, so creating a name that exists returns
# that tag with created: false, which also makes a retry safe. Hand port of upstream 974f1d8e4.
class Assistant::Function::CreateTag < Assistant::Function
  scope_tag :write

  HEX_COLOR = /\A#\h{6}\z/

  class << self
    def name
      "create_tag"
    end

    def description
      <<~INSTRUCTIONS
        Creates a tag, a label for transactions beside their category. color is
        a hex code such as #e99537 (a palette color if omitted).

        Tag names are unique in the family: if the name exists, the existing tag
        comes back with created: false and nothing changes. Apply tags with
        update_transaction's tag_ids.
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
        name: { type: "string", description: "Tag name, unique in the family" },
        color: { type: "string", description: "Hex color such as #e99537" }
      }
    )
  end

  def record_type
    "Tag"
  end

  def call(params = {})
    name = params["name"].to_s.squish
    return tool_error("invalid_name", "name is required.") if name.empty?

    if (existing = family.tags.find_by(name: name))
      return { id: existing.id, created: false, tag: tag_snapshot(existing) }
    end

    color = params["color"].presence || Tag::COLORS.sample
    return tool_error("invalid_color", "color must be a hex code such as #e99537.") unless HEX_COLOR.match?(color)

    tag = family.tags.create!(name: name, color: color)

    { id: tag.id, created: true, tag: tag_snapshot(tag) }
  end

  private
    def tag_snapshot(tag)
      { id: tag.id, name: tag.name, color: tag.color }
    end
end
