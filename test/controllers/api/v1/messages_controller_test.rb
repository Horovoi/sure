# frozen_string_literal: true

require "test_helper"

class Api::V1::MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test API App",
      redirect_uri: "https://example.com/callback",
      scopes: "read write read_write"
    )

    @write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    @chat = chats(:one)
  end

  test "should require authentication" do
    post "/api/v1/chats/#{@chat.id}/messages"
    assert_response :unauthorized
  end

  test "should require AI to be enabled" do
    @user.update!(ai_enabled: false)

    post "/api/v1/chats/#{@chat.id}/messages",
      params: { content: "Hello" },
      headers: bearer_auth_header(@write_token)
    assert_response :forbidden
  end

  test "should create message with write scope" do
    assert_difference "Message.count", 2 do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Test message", model: "gpt-4" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal "Test message", response_body["content"]
    assert_equal "user_message", response_body["type"]
    assert_equal "pending", response_body["ai_response_status"]
    assert_equal @chat.in_flight_turn.id, response_body["ai_response_message_id"]
  end

  test "reports the real status of the response" do
    turn = @chat.ask!("Question", ai_model: "gpt-4.1")
    turn.start!
    turn.append_text!("Answer")
    turn.complete!("resp_1")

    get "/api/v1/chats/#{@chat.id}", headers: bearer_auth_header(@write_token)

    messages = JSON.parse(response.body)["messages"]
    assert_equal "complete", messages.find { |m| m["id"] == turn.id }["status"]
  end

  test "should enqueue assistant response job" do
    assert_enqueued_with(job: AssistantResponseJob) do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Test message" },
        headers: bearer_auth_header(@write_token)
    end
  end

  test "should not create a message while a response is being generated" do
    @chat.ask!("First", ai_model: "gpt-4.1")

    assert_no_difference "Message.count" do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Second" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :conflict
  end

  test "should retry a failed response" do
    turn = @chat.ask!("Question", ai_model: "gpt-4.1")
    turn.start!
    turn.fail!(StandardError.new("boom"))
    clear_enqueued_jobs

    assert_enqueued_with(job: AssistantResponseJob, args: [ turn ]) do
      post "/api/v1/chats/#{@chat.id}/messages/retry",
        headers: bearer_auth_header(@write_token)
    end

    assert_response :accepted
    assert_equal turn.id, JSON.parse(response.body)["message_id"]
    assert turn.reload.pending?
  end

  test "should not retry while a response is being generated" do
    @chat.ask!("Question", ai_model: "gpt-4.1")

    post "/api/v1/chats/#{@chat.id}/messages/retry",
      headers: bearer_auth_header(@write_token)

    assert_response :conflict
  end

  test "should not retry a completed response" do
    post "/api/v1/chats/#{@chat.id}/messages/retry.json",
      headers: bearer_auth_header(@write_token)

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "Nothing to retry", response_body["error"]
  end

  test "should not access messages in other user's chat" do
    other_user = users(:family_member)
    other_user.update!(family: families(:empty))
    other_chat = chats(:two)
    other_chat.update!(user: other_user)

    post "/api/v1/chats/#{other_chat.id}/messages",
      params: { content: "Test" },
      headers: bearer_auth_header(@write_token)

    assert_response :not_found
  end

  private

    def bearer_auth_header(token)
      { "Authorization" => "Bearer #{token.token}" }
    end
end
