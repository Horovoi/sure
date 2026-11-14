require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @chat = @user.chats.first
  end

  test "can create a message" do
    post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "gpt-4.1" } }

    assert_redirected_to chat_path(@chat)
    assert @chat.turn_in_flight?
  end

  test "cannot send a message while a response is being generated" do
    @chat.ask!("First", ai_model: "gpt-4.1")

    assert_no_difference "Message.count" do
      post chat_messages_url(@chat), params: { message: { content: "Second", ai_model: "gpt-4.1" } }
    end

    assert_redirected_to chat_path(@chat)
    assert_equal I18n.t("messages.create.in_progress"), flash[:alert]
  end

  test "cannot create a message if AI is disabled" do
    @user.update!(ai_enabled: false)

    post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "gpt-4.1" } }

    assert_response :forbidden
  end
end
