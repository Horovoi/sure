require "test_helper"

class AssistantMessageTest < ActiveSupport::TestCase
  setup do
    @chat = chats(:one)
    @chat.update!(latest_assistant_response_id: "resp_previous")
  end

  test "broadcasts append after creation" do
    message = AssistantMessage.create!(chat: @chat, content: "Hello from assistant", ai_model: "gpt-4.1")
    message.update!(content: "updated")

    streams = capture_turbo_stream_broadcasts(@chat)
    assert_equal 2, streams.size
    assert_equal "append", streams.first["action"]
    assert_equal "messages", streams.first["target"]
    assert_equal "replace", streams.last["action"]
    assert_equal "assistant_message_#{message.id}", streams.last["target"]
  end

  test "a new assistant message is a pending turn with blank content" do
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1")

    assert turn.pending?
    assert turn.in_flight?
    assert_equal "", turn.content
  end

  test "a complete message needs content" do
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1", status: "streaming")

    assert_raises(ActiveRecord::RecordInvalid) { turn.complete!("resp_new") }
    assert turn.reload.streaming?
  end

  test "completion moves the response pointer" do
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1", status: "streaming", content: "Hi")
    @chat.update!(error: "old".to_json)

    turn.complete!("resp_new")

    assert turn.reload.complete?
    assert_equal "resp_new", turn.provider_id
    assert_equal "resp_new", @chat.reload.latest_assistant_response_id
    assert_nil @chat.error
  end

  test "failure keeps the response pointer and records the error" do
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1", status: "streaming", content: "Partial")

    turn.fail!(StandardError.new("boom"))

    assert turn.reload.failed?
    assert_equal "Partial", turn.content
    assert_equal "resp_previous", @chat.reload.latest_assistant_response_id
    assert_includes @chat.error, "boom"
  end

  test "a turn whose completion is rejected fails instead of staying in flight" do
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1", status: "streaming")
    error = assert_raises(ActiveRecord::RecordInvalid) { turn.complete!("resp_new") }

    turn.fail_turn(error)

    assert turn.reload.failed?
    assert_nil turn.provider_id
    assert_equal "resp_previous", @chat.reload.latest_assistant_response_id
  end

  test "fail_turn ignores a turn that already ended" do
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1", status: "complete", content: "Done")

    assert_nothing_raised { turn.fail_turn(StandardError.new("late")) }
    assert turn.reload.complete?
  end

  test "stale scope finds in-flight turns with no recent progress" do
    fresh = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1", status: "streaming")
    lost = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1", status: "streaming")
    lost.update_column(:updated_at, (AssistantMessage::STALE_AFTER + 1.minute).ago)

    assert_equal [ lost ], AssistantMessage.stale.to_a
    assert lost.stale?
    assert_not fresh.stale?
  end

  test "generate_response does nothing for a turn another run already claimed" do
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1", status: "streaming")
    Chat.any_instance.expects(:assistant).never

    turn.generate_response

    assert turn.reload.streaming?
  end

  test "generate_response fails the turn when AI is disabled" do
    @chat.user.update!(ai_enabled: false)
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1")
    Chat.any_instance.expects(:assistant).never

    turn.generate_response

    assert turn.reload.failed?
    assert_includes @chat.reload.error, "AI is disabled"
  end

  test "generate_response fails the turn when the assistant cannot be built" do
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1")
    Assistant.expects(:for_chat).raises(StandardError, "config broke")

    assert_nothing_raised { turn.generate_response }

    assert turn.reload.failed?
    assert_includes @chat.reload.error, "config broke"
  end

  test "an OpenAI stream failure fails the turn with the provider message, and the turn can be retried" do
    UserMessage.create!(chat: @chat, content: "What is my net worth?", ai_model: "gpt-4.1")
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1")

    provider = Provider::Openai.new("test-token")
    responses = Object.new
    responses.define_singleton_method(:create) do |parameters:|
      parameters[:stream].call({ "type" => "response.output_text.delta", "delta" => "Your net" })
      parameters[:stream].call({ "type" => "response.failed", "response" => { "error" => { "message" => "Previous response not found", "code" => "previous_response_not_found" } } })
      nil
    end
    provider.send(:client).stubs(:responses).returns(responses)
    Assistant.any_instance.stubs(:get_model_provider).with("gpt-4.1").returns(provider)

    assert_difference -> { @chat.user.family.llm_usages.count }, 1 do
      turn.generate_response
    end

    assert turn.reload.failed?
    assert_includes @chat.reload.error, "Previous response not found"
    assert_equal "resp_previous", @chat.latest_assistant_response_id
    assert turn.retryable?

    assert_enqueued_with(job: AssistantResponseJob) do
      assert_equal turn, @chat.retry_last_turn!
    end
    assert turn.reload.pending?
    assert_equal "", turn.content
  end

  test "a pending turn queued 15 minutes ago is not stale" do
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1")
    turn.update_column(:updated_at, 15.minutes.ago)

    assert_not_includes AssistantMessage.stale, turn
    assert_not turn.stale?
    assert turn.live?
  end

  test "a pending turn queued 31 minutes ago is stale" do
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1")
    turn.update_column(:updated_at, 31.minutes.ago)

    assert_includes AssistantMessage.stale, turn
    assert turn.stale?
    assert_not turn.live?
    assert turn.retryable?
  end

  test "a streaming turn with no progress for 11 minutes is stale" do
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1", status: "streaming")
    turn.update_column(:updated_at, 11.minutes.ago)

    assert_includes AssistantMessage.stale, turn
    assert turn.stale?
    assert_not turn.live?
  end

  test "a requeued old turn is not stale" do
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1", status: "failed")
    turn.update_columns(created_at: 2.hours.ago, updated_at: 2.hours.ago)

    turn.requeue!

    assert turn.reload.pending?
    assert turn.created_at < 1.hour.ago
    assert_not_includes AssistantMessage.stale, turn
    assert_not turn.stale?
    assert turn.live?
  end

  test "the stale work reaper fails only the stale turns" do
    queued = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1")
    queued.update_column(:updated_at, 15.minutes.ago)
    lost_queued = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1")
    lost_queued.update_column(:updated_at, 31.minutes.ago)
    lost_streaming = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1", status: "streaming", content: "Partial")
    lost_streaming.update_column(:updated_at, 11.minutes.ago)
    streaming = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1", status: "streaming")

    result = StaleWorkReaperJob.perform_now

    assert_equal 2, result["AssistantMessage"]
    assert lost_queued.reload.failed?
    assert lost_streaming.reload.failed?
    assert queued.reload.pending?
    assert streaming.reload.streaming?
  end
end
