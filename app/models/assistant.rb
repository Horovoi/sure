class Assistant
  include Provided, Configurable, Broadcastable

  attr_reader :chat, :instructions

  TOOL_SCOPES = %i[read full].freeze

  class << self
    def for_chat(chat)
      config = config_for(chat)
      new(chat, instructions: config[:instructions], functions: config[:functions])
    end

    # Every tool, in one fixed order: the in-app chat and /mcp both serve this list (tools/list keeps the order).
    # Each tool unit adds its classes in its own block.
    def function_classes
      [
        # Reads: accounts and balances, income and spending, transactions, holdings, reference data
        Assistant::Function::GetAccounts,
        Assistant::Function::GetBalanceSheet,
        Assistant::Function::GetIncomeStatement,
        Assistant::Function::GetTransactions,
        Assistant::Function::GetHoldings,
        Assistant::Function::GetValuations,
        Assistant::Function::GetCategories,
        Assistant::Function::GetTags,
        Assistant::Function::GetMerchants,
        Assistant::Function::SearchFamilyFiles,

        # Imports
        Assistant::Function::ImportBankStatement
      ]
    end

    # The tools one caller may use, in the fixed order of function_classes. :full is every tool: the in-app
    # chat and both MCP tokens use it (owner answer 2). :read keeps only the :read-tagged tools, for tests and a
    # future read-only token.
    def function_classes_for(scope)
      case scope
      when :full then function_classes
      when :read then function_classes.select(&:read_only?)
      else raise ArgumentError, "Unknown tool scope #{scope.inspect}; use one of #{TOOL_SCOPES.inspect}"
      end
    end
  end

  def initialize(chat, instructions: nil, functions: [])
    @chat = chat
    @instructions = instructions
    @functions = functions
  end

  # Streams the response for a claimed (streaming) assistant message and completes it.
  # Raises on failure; AssistantMessage#generate_response fails the turn.
  def respond_to(assistant_message)
    prompt = assistant_message.prompt
    raise StandardError, "No user message to respond to" unless prompt

    llm_provider = get_model_provider(assistant_message.ai_model)

    unless llm_provider
      error_message = build_no_provider_error_message(assistant_message.ai_model)
      raise StandardError, error_message
    end

    responder = Assistant::Responder.new(
      message: prompt,
      instructions: instructions,
      function_tool_caller: function_tool_caller(assistant_message),
      llm: llm_provider
    )

    responder.on(:output_text) do |text|
      assistant_message.append_text!(text)
    end

    responder.on(:function_tool_calls) do |function_tool_calls|
      # Saved right away, so they stay with the turn even if a later request fails
      assistant_message.tool_calls << function_tool_calls
      update_thinking("Analyzing your data...")
    end

    final_response = responder.respond(previous_response_id: chat.latest_assistant_response_id)

    assistant_message.complete!(final_response.id)
  end

  private
    attr_reader :functions

    # Built per turn, so every tool call is audited with the assistant message it answers
    def function_tool_caller(assistant_message)
      function_instances = functions.map do |fn|
        fn.new(chat.user)
      end

      FunctionToolCaller.new(function_instances, actor: ToolInvocation::Actor.builtin_chat(assistant_message))
    end

    def build_no_provider_error_message(requested_model)
      available_providers = registry.providers

      if available_providers.empty?
        "No LLM provider configured that supports model '#{requested_model}'. " \
        "Please configure an LLM provider (e.g., OpenAI) in settings."
      else
        provider_details = available_providers.map do |provider|
          "  - #{provider.provider_name}: #{provider.supported_models_description}"
        end.join("\n")

        "No LLM provider configured that supports model '#{requested_model}'.\n\n" \
        "Available providers:\n#{provider_details}\n\n" \
        "Please either:\n" \
        "  1. Use a supported model from the list above, or\n" \
        "  2. Configure a provider that supports '#{requested_model}' in settings."
      end
    end
end
