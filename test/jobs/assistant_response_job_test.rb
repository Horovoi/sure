require "test_helper"

class AssistantResponseJobTest < ActiveJob::TestCase
  setup do
    @chat = chats(:one)
  end

  test "generates the response of a pending turn" do
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1")
    AssistantMessage.any_instance.expects(:generate_response).once

    AssistantResponseJob.perform_now(turn)
  end

  test "a re-run of a claimed turn does not call the assistant again" do
    turn = AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1", status: "streaming")
    Chat.any_instance.expects(:assistant).never

    AssistantResponseJob.perform_now(turn)

    assert turn.reload.streaming?
  end

  test "a job queued by the previous version answers its unanswered prompt" do
    chat = chats(:two)
    AssistantMessage.any_instance.expects(:generate_response).once

    assert_difference -> { chat.messages.where(type: "AssistantMessage").count }, 1 do
      AssistantResponseJob.perform_now(messages(:chat2_user))
    end
  end

  test "a job queued by the previous version for an answered prompt does nothing" do
    AssistantMessage.any_instance.expects(:generate_response).never

    assert_no_difference "AssistantMessage.count" do
      AssistantResponseJob.perform_now(messages(:chat1_user))
    end
  end

  test "runs in the AI lane, ahead of batch AI work" do
    assert_equal "ai_high_priority", AssistantResponseJob.queue_name

    assert_enqueued_with(job: AssistantResponseJob, queue: "ai_high_priority") do
      AssistantMessage.create!(chat: @chat, ai_model: "gpt-4.1").respond_later
    end
  end
end
