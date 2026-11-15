require "test_helper"

class Assistant::FunctionTest < ActiveSupport::TestCase
  class EmptyEnumFunction < Assistant::Function
    class << self
      def name
        "empty_enum_function"
      end

      def description
        "Test function with data-driven enums"
      end
    end

    def call(params = {})
      {}
    end

    def params_schema
      build_schema(
        required: [ "name" ],
        properties: {
          name: {
            type: "string",
            description: "Property-level enum built from empty family data",
            enum: []
          },
          accounts: {
            type: "array",
            description: "Items-level enum built from empty family data",
            items: { enum: [] },
            minItems: 1,
            uniqueItems: true
          },
          order: {
            enum: [ "asc", "desc" ],
            description: "Static enum that must be kept"
          }
        }
      )
    end
  end

  setup do
    @function = EmptyEnumFunction.new(users(:family_admin))
  end

  test "drops empty enums so strict providers accept the schema" do
    properties = @function.to_definition[:params_schema][:properties]

    refute properties[:name].key?(:enum)
    assert_equal "string", properties[:name][:type]

    refute properties[:accounts][:items].key?(:enum)
    assert_equal "string", properties[:accounts][:items][:type]
    assert_equal 1, properties[:accounts][:minItems]
  end

  test "keeps populated enums and the surrounding schema" do
    schema = @function.to_definition[:params_schema]

    assert_equal [ "asc", "desc" ], schema[:properties][:order][:enum]
    assert_equal [ "name" ], schema[:required]
    assert_equal "object", schema[:type]
    assert_equal false, schema[:additionalProperties]
  end

  test "keeps populated enum values verbatim, including literal objects and arrays" do
    schema = {
      status: { enum: [ { enum: [] }, [ "nested" ] ] },
      order: { enum: [ "asc" ] }
    }

    pruned = @function.send(:prune_empty_enums, schema)

    assert_equal [ { enum: [] }, [ "nested" ] ], pruned[:status][:enum]
    assert_equal [ "asc" ], pruned[:order][:enum]
  end

  test "no registered function emits an empty enum for a family with no data" do
    user = users(:empty)
    user.family.tags.destroy_all
    user.family.merchants.destroy_all
    assert_empty user.family.accounts

    Assistant.function_classes.each do |function_class|
      definition = function_class.new(user).to_definition
      assert_no_empty_enums definition[:params_schema], function_class.name
    end
  end

  # --- Scope tags ---------------------------------------------------------------------------------------

  test "every registered function has a known scope tag" do
    Assistant.function_classes.each do |function_class|
      assert_includes Assistant::Function::SCOPE_TAGS, function_class.scope_tag, function_class.name
    end
  end

  test "mcp annotations follow the scope tag and no read tool is destructive" do
    user = users(:family_admin)

    Assistant.function_classes.each do |function_class|
      annotations = function_class.new(user).mcp_annotations
      tag = function_class.scope_tag

      assert_equal tag == :read, annotations[:read_only_hint], "#{function_class.name} readOnlyHint"
      assert_equal tag == :destructive, annotations[:destructive_hint], "#{function_class.name} destructiveHint"
      refute annotations[:destructive_hint], "#{function_class.name} reads but claims destructiveHint" if tag == :read
    end
  end

  test "a tool declares its tag once and subclasses inherit it" do
    write_tool = Class.new(EmptyEnumFunction) { scope_tag :write }
    destructive_tool = Class.new(write_tool) { scope_tag :destructive }

    assert_equal :read, EmptyEnumFunction.scope_tag
    assert_equal :write, write_tool.scope_tag
    assert_equal :write, Class.new(write_tool).scope_tag
    assert_equal :destructive, destructive_tool.scope_tag

    annotations = destructive_tool.new(users(:family_admin)).mcp_annotations
    assert_equal({ read_only_hint: false, destructive_hint: true, idempotent_hint: false, open_world_hint: false }, annotations)
  end

  test "an unknown scope tag is refused" do
    assert_raises(ArgumentError) { Class.new(EmptyEnumFunction) { scope_tag :admin } }
  end

  test "reads have no audit snapshot or record type by default" do
    function = EmptyEnumFunction.new(users(:family_admin))

    assert_nil function.audit_before({})
    assert_nil function.record_type
  end

  private
    def assert_no_empty_enums(node, function_name, location = "params_schema")
      case node
      when Hash
        node.each do |key, value|
          refute key.to_sym == :enum && value == [],
            "#{function_name} emits an empty enum at #{location}.#{key}, which is invalid JSON Schema"
          assert_no_empty_enums(value, function_name, "#{location}.#{key}")
        end
      when Array
        node.each_with_index do |value, index|
          assert_no_empty_enums(value, function_name, "#{location}[#{index}]")
        end
      end
    end
end
