require "test_helper"

class Assistant::Function::SchemaStrictnessTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
  end

  # Strict function calling requires every declared property to appear in required. A strict tool with an optional
  # property is an invalid schema that strict providers reject wholesale.
  test "strict functions declare every property as required" do
    assert_operator Assistant.function_classes.size, :>=, 11,
      "the tool registry looks empty or truncated, so the walk would prove nothing"

    Assistant.function_classes.each do |function_class|
      definition = function_class.new(@user).to_definition
      next unless definition[:strict]

      schema = definition[:params_schema]
      property_keys = schema[:properties].keys.map(&:to_s)
      required_keys = Array(schema[:required]).map(&:to_s)

      assert_equal property_keys.sort, required_keys.sort,
        "#{definition[:name]} is strict but properties #{property_keys - required_keys} are not required"
    end
  end

  test "every chat schema is a closed object and every MCP schema compiles" do
    Assistant.function_classes.each do |function_class|
      function = function_class.new(@user)
      schema = function.params_schema

      assert_equal "object", schema[:type], function.name
      assert_equal false, schema[:additionalProperties], "#{function.name} must not accept unknown arguments"
      assert JSONSchemer.schema(function.mcp_input_schema.deep_stringify_keys).valid_schema?,
        "#{function.name} has an invalid MCP input schema"
    end
  end
end
