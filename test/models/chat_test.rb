require "test_helper"

class ChatTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @assistant = mock
  end

  test "user sees all messages in debug mode" do
    chat = chats(:one)
    with_env_overrides AI_DEBUG_MODE: "true" do
      assert_equal chat.messages.count, chat.conversation_messages.count
    end
  end

  test "user sees assistant and user messages in normal mode" do
    chat = chats(:one)
    assert_equal 3, chat.conversation_messages.count
  end

  test "creates with initial message and a pending turn" do
    prompt = "Test prompt"

    assert_difference "@user.chats.count", 1 do
      chat = @user.chats.start!(prompt, model: "gpt-4.1")

      assert_equal 1, chat.messages.where(type: "UserMessage").count
      turn = chat.messages.find_by!(type: "AssistantMessage")
      assert turn.pending?
      assert_equal "gpt-4.1", turn.ai_model
      assert_enqueued_with job: AssistantResponseJob, args: [ turn ]
    end
  end

  test "start! uses the given title" do
    chat = @user.chats.start!("Prompt", model: nil, title: "My title")
    assert_equal "My title", chat.title
  end

  test "creates with default model when model is nil" do
    chat = @user.chats.start!("Test prompt", model: nil)

    assert_equal [ Provider::Openai::DEFAULT_MODEL ], chat.messages.pluck(:ai_model).uniq
  end

  test "creates with default model when model is empty string" do
    chat = @user.chats.start!("Test prompt", model: "")

    assert_equal [ Provider::Openai::DEFAULT_MODEL ], chat.messages.pluck(:ai_model).uniq
  end

  test "creates with configured model when OPENAI_MODEL env is set" do
    with_env_overrides OPENAI_MODEL: "custom-model" do
      chat = @user.chats.start!("Test prompt", model: "")

      assert_equal "custom-model", chat.messages.first.ai_model
    end
  end

  test "ask! saves the prompt and a pending turn and queues the turn" do
    chat = chats(:one)

    turn = assert_difference -> { chat.messages.count }, 2 do
      chat.ask!("How much did I spend?", ai_model: "gpt-4.1")
    end

    assert turn.pending?
    assert_equal "How much did I spend?", turn.prompt.content
    assert_equal turn, turn.prompt.reply
    assert chat.turn_in_flight?
    assert_enqueued_with job: AssistantResponseJob, args: [ turn ]
  end

  test "ask! refuses a second prompt while a turn runs" do
    chat = chats(:one)
    chat.ask!("First", ai_model: "gpt-4.1")

    assert_no_difference -> { chat.messages.count } do
      assert_raises(Chat::TurnInProgressError) { chat.ask!("Second", ai_model: "gpt-4.1") }
    end
  end

  test "ask! fails a lost turn and starts the new one" do
    chat = chats(:one)
    lost = chat.ask!("First", ai_model: "gpt-4.1")
    lost.start!
    lost.update_column(:updated_at, (AssistantMessage::STALE_AFTER + 1.minute).ago)

    turn = chat.ask!("Second", ai_model: "gpt-4.1")

    assert lost.reload.failed?
    assert turn.pending?
  end

  test "retry requeues a failed turn as the same message" do
    chat = chats(:one)
    turn = chat.ask!("Question", ai_model: "gpt-4.1")
    turn.start!
    turn.append_text!("partial")
    turn.tool_calls.create!(type: "ToolCall::Function", provider_id: "fc_1", provider_call_id: "call_1", function_name: "get_accounts", function_arguments: {}, function_result: { "ok" => true })
    turn.fail!(StandardError.new("boom"))
    clear_enqueued_jobs

    assert_no_difference -> { chat.messages.count } do
      assert_equal turn, chat.retry_last_turn!
    end

    turn.reload
    assert turn.pending?
    assert_equal "", turn.content
    assert_empty turn.tool_calls
    assert_nil chat.reload.error
    assert_enqueued_with job: AssistantResponseJob, args: [ turn ]
  end

  test "retry is refused while a turn runs" do
    chat = chats(:one)
    chat.ask!("Question", ai_model: "gpt-4.1")
    clear_enqueued_jobs

    assert_raises(Chat::TurnInProgressError) { chat.retry_last_turn! }
    assert_no_enqueued_jobs
  end

  test "retry of a lost turn fails it and runs it again" do
    chat = chats(:one)
    turn = chat.ask!("Question", ai_model: "gpt-4.1")
    turn.start!
    turn.update_column(:updated_at, (AssistantMessage::STALE_AFTER + 1.minute).ago)
    assert chat.retryable?

    assert_equal turn, chat.retry_last_turn!
    assert turn.reload.pending?
  end

  test "retry answers a prompt that never got a turn" do
    chat = chats(:two) # its last message is a user message with no reply
    assert chat.unanswered_prompt?
    assert chat.retryable?

    turn = assert_difference -> { chat.messages.where(type: "AssistantMessage").count }, 1 do
      chat.retry_last_turn!
    end

    assert turn.pending?
    assert_equal messages(:chat2_user), turn.prompt
    assert_not chat.unanswered_prompt?
  end

  test "nothing to retry after a completed turn" do
    chat = chats(:one)

    assert_not chat.retryable?
    assert_raises(Chat::NothingToRetryError) { chat.retry_last_turn! }
  end

  test "adopts a prompt queued by the previous version once" do
    chat = chats(:two)
    prompt = messages(:chat2_user)

    turn = chat.adopt_unanswered_prompt(prompt)
    assert turn.pending?
    assert_nil chat.adopt_unanswered_prompt(prompt)
  end
end
