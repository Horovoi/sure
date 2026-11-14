require "test_helper"

class UserMessageTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @chat = chats(:one)
  end

  test "broadcasts append after creation and replace after update" do
    message = UserMessage.create!(chat: @chat, content: "Hello from user", ai_model: "gpt-4.1")
    message.update!(content: "updated")

    streams = capture_turbo_stream_broadcasts(@chat)
    assert_equal 2, streams.size
    assert_equal "append", streams.first["action"]
    assert_equal "messages", streams.first["target"]
    assert_equal "replace", streams.last["action"]
    assert_equal "user_message_#{message.id}", streams.last["target"]
  end

  test "creating a user message alone does not start a turn" do
    assert_no_enqueued_jobs only: AssistantResponseJob do
      UserMessage.create!(chat: @chat, content: "Hello from user", ai_model: "gpt-4.1")
    end
  end
end
