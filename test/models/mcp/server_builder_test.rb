require "test_helper"

class Mcp::ServerBuilderTest < ActiveSupport::TestCase
  class NullableFunction < Assistant::Function
    class << self
      def name
        "nullable_function"
      end

      def description
        "Test function with a nullable property"
      end
    end

    def call(params = {})
      { received: params }
    end

    def params_schema
      build_schema(
        required: [ "query", "limit" ],
        properties: {
          query: { type: "string" },
          limit: { type: [ "integer", "null" ] },
          tags: { type: "array", items: { enum: [] } }
        }
      )
    end
  end

  setup do
    @user = users(:empty)
    @user.family.tags.destroy_all
    @user.family.merchants.destroy_all
    @credential = Mcp::Credential.static(@user)
  end

  test "builds a server named sure with every tool in the registry order" do
    server = Mcp::ServerBuilder.build(@credential)

    assert_equal "sure", server.name
    assert_equal Sure.version.to_s, server.version
    assert_equal Assistant.function_classes.map(&:name), server.tools.keys
    assert_equal Mcp::ServerBuilder::LIST_TTL_MS, server.ttl_ms
    assert_equal "private", server.cache_scope
  end

  test "the instructions describe the family's currency, rates and time zone" do
    @user.family.update!(currency: "UAH", timezone: "Europe/Kyiv")

    instructions = Mcp::ServerBuilder.build(@credential).instructions

    assert_match "UAH", instructions
    assert_match "National Bank of Ukraine", instructions
    assert_match "Europe/Kyiv", instructions
    assert_match "entered by hand", instructions
  end

  test "every input schema compiles on an empty family and has no empty enum" do
    Mcp::ServerBuilder.new(@credential).tools.each do |tool|
      schema = tool.input_schema.to_h

      assert JSONSchemer.schema(schema.deep_stringify_keys).valid_schema?, "#{tool.name_value} has an invalid input schema"
      refute_match(/"enum":\[\]/, schema.to_json, "#{tool.name_value} serves an empty enum")
    end
  end

  test "every tool accepts a call with only its required, non-nullable arguments" do
    Mcp::ServerBuilder.new(@credential).tools.each do |tool|
      schema = tool.input_schema.to_h.deep_symbolize_keys
      arguments = Array(schema[:required]).index_with { |key| sample_value(schema.dig(:properties, key.to_sym)) }

      refute tool.input_schema.missing_required_arguments?(arguments), "#{tool.name_value} requires more than its required list"
      assert_nothing_raised("#{tool.name_value} rejects #{arguments}") { tool.input_schema.validate_arguments(arguments) }
    end
  end

  test "mcp_input_schema makes nullable properties optional and prunes empty enums" do
    schema = NullableFunction.new(@user).mcp_input_schema

    assert_equal [ "query" ], schema[:required]
    assert_equal "string", schema.dig(:properties, :tags, :items, :type)
    refute schema.dig(:properties, :tags, :items).key?(:enum)
    # The chat schema keeps what the provider expects
    assert_equal [ "query", "limit" ], NullableFunction.new(@user).params_schema[:required]
  end

  test "call_tool returns the result as text and structured content" do
    builder = Mcp::ServerBuilder.new(@credential)

    response = builder.call_tool(NullableFunction, { query: "rent" })

    refute response.error?
    assert_equal({ "received" => { "query" => "rent" } }, response.structured_content)
    assert_equal response.structured_content, JSON.parse(response.content.first[:text])
  end

  test "call_tool turns an exception into a sanitised error result" do
    NullableFunction.any_instance.stubs(:call).raises(RuntimeError, "secret internals")
    builder = Mcp::ServerBuilder.new(@credential)

    response = builder.call_tool(NullableFunction, {})

    assert response.error?
    assert_equal "nullable_function failed unexpectedly", response.structured_content["error"]
    refute_match "secret", response.content.first[:text]
  end

  test "read tools are annotated read-only and the statement import is not" do
    assert_equal({ read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false },
      Assistant::Function::GetAccounts.new(@user).mcp_annotations)

    import = Assistant::Function::ImportBankStatement.new(@user).mcp_annotations
    assert_equal false, import[:read_only_hint]
    assert_equal false, import[:idempotent_hint]
    assert_equal true, import[:open_world_hint]
  end

  test "a credential needs a known kind, a known scope and a user" do
    assert_raises(ArgumentError) { Mcp::Credential.new(user: @user, kind: :oauth) }
    assert_raises(ArgumentError) { Mcp::Credential.new(user: @user, kind: :static, scope: :admin) }
    assert_raises(ArgumentError) { Mcp::Credential.new(user: nil, kind: :static) }
    assert_equal :full, @credential.scope
    assert @credential.static?
  end

  test "the static and turn tokens both get the full tool set" do
    turn = Mcp::Credential.turn(@user, assistant_message: nil)

    assert_equal :full, turn.scope
    assert turn.turn?
    assert_equal Assistant.function_classes_for(:full), turn.function_classes
    assert_equal Assistant.function_classes_for(:full), @credential.function_classes
  end

  test "a read-scope server registers only the read tools" do
    credential = Mcp::Credential.new(user: @user, kind: :static, scope: :read)

    names = Mcp::ServerBuilder.build(credential).tools.keys

    assert_equal Assistant.function_classes_for(:read).map(&:name), names
    assert_not_includes names, "import_bank_statement"
  end

  test "call_tool marks a soft {error, hint} result as a tool error" do
    NullableFunction.any_instance.stubs(:call).returns({ error: "invalid_date", hint: "Use YYYY-MM-DD." })

    response = Mcp::ServerBuilder.new(@credential).call_tool(NullableFunction, { query: "x" })

    assert response.error?
    assert_equal "invalid_date", response.structured_content["error"]
  end

  private
    def sample_value(property)
      property ||= {}
      return property[:enum].first if property[:enum].present?

      case Array(property[:type]).first.to_s
      when "integer", "number" then 1
      when "boolean" then true
      when "array" then []
      when "object" then {}
      else "2026-01-01"
      end
    end
end
