require "test_helper"

class ChatsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @family = families(:dylan_family)
    sign_in @user
  end

  test "gets index" do
    get chats_url
    assert_response :success
  end

  test "with no AI engine the AI box says how to connect one" do
    @user.update!(ai_enabled: false)

    without_ai_engine do
      get chats_url
    end

    assert_response :success
    assert_select "[data-testid=ai-setup]" do
      assert_select "h3", text: I18n.t("chats.ai_consent.setup_title")
      assert_select "p", text: I18n.t("chats.ai_consent.claude_body")
      assert_select "p", text: I18n.t("chats.ai_consent.openai_body")
      assert_select "a[href=?]", settings_ai_prompts_path, text: I18n.t("chats.ai_consent.setup_button")
      assert_select "a[href=?]", settings_hosting_path, text: I18n.t("chats.ai_consent.openai_button")
    end
    assert_select "form[action=?]", user_path(@user), count: 0
    assert_no_match "OPENAI_ACCESS_TOKEN", response.body
    assert_no_match(/anonymi[sz]ed/i, response.body)
  end

  test "with an AI engine but AI off the AI box offers to turn AI on" do
    @user.update!(ai_enabled: false)

    without_ai_engine do
      with_env_overrides CLAUDE_BRIDGE_URL: "http://host.docker.internal:3339", CLAUDE_BRIDGE_TOKEN: "t" * 40 do
        get chats_url
      end
    end

    assert_response :success
    assert_select "[data-testid=ai-consent]" do
      assert_select "h3", text: I18n.t("chats.ai_consent.enable_title")
      assert_select "form[action=?]", user_path(@user) do
        assert_select "input[name=?][value=?]", "user[ai_enabled]", "true"
        assert_select "button", text: I18n.t("chats.ai_consent.enable_button")
      end
    end
    assert_select "[data-testid=ai-setup]", count: 0
  end

  test "with AI on there is no AI box" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token" do
      @user.update!(ai_enabled: true)
      get chats_url
    end

    assert_response :success
    assert_select "[data-testid=ai-consent]", count: 0
  end

  test "creates chat" do
    assert_difference("Chat.count") do
      post chats_url, params: { chat: { content: "Hello", ai_model: "gpt-4.1" } }
    end

    assert_redirected_to chat_path(Chat.order(created_at: :desc).first)
  end

  test "cannot create a chat if AI is disabled" do
    @user.update!(ai_enabled: false)

    assert_no_difference("Chat.count") do
      post chats_url, params: { chat: { content: "Hello", ai_model: "gpt-4.1" } }
    end

    assert_response :forbidden
  end

  test "shows a pending turn as thinking with the composer disabled" do
    chat = chats(:one)
    chat.ask!("Question", ai_model: "gpt-4.1")

    get chat_url(chat)

    assert_response :success
    assert_select "[data-turn-in-flight=true] #thinking-indicator"
    assert_select "#chat-form button[type=submit][disabled]"
    assert_select "#chat-error", count: 0
  end

  test "shows retry for a failed turn" do
    chat = chats(:one)
    turn = chat.ask!("Question", ai_model: "gpt-4.1")
    turn.start!
    turn.fail!(StandardError.new("boom"))

    get chat_url(chat)

    assert_select "#chat-error form[action='#{retry_chat_path(chat)}']"
    assert_select "#chat-form button[type=submit]:not([disabled])"
  end

  test "shows retry only for the last turn" do
    chat = chats(:one)
    failed = chat.ask!("Question", ai_model: "gpt-4.1")
    failed.start!
    failed.fail!(StandardError.new("boom"))
    answered = chat.ask!("Again", ai_model: "gpt-4.1")
    answered.start!
    answered.append_text!("Answer")
    answered.complete!("resp_2")

    get chat_url(chat)

    assert_select "#chat-error", count: 0
  end

  test "shows retry for a lost turn" do
    chat = chats(:one)
    turn = chat.ask!("Question", ai_model: "gpt-4.1")
    # Still pending: a queued turn is lost only after the longer pending wait
    turn.update_column(:updated_at, (AssistantMessage::PENDING_STALE_AFTER + 1.minute).ago)

    get chat_url(chat)

    assert_select "#chat-error form[action='#{retry_chat_path(chat)}']"
    assert_select "#thinking-indicator", count: 0
  end

  test "shows retry for a prompt that never got a response" do
    chat = @user.chats.create!(title: "Orphan")
    UserMessage.create!(chat: chat, content: "Anyone?", ai_model: "gpt-4.1")

    get chat_url(chat)

    assert_select "#chat-error form[action='#{retry_chat_path(chat)}']"
  end

  test "retry retries the chat in the URL, not the last viewed chat" do
    chat = @user.chats.create!(title: "Failed one")
    turn = chat.ask!("Question", ai_model: "gpt-4.1")
    turn.start!
    turn.fail!(StandardError.new("boom"))
    @user.update!(last_viewed_chat: chats(:one))
    clear_enqueued_jobs

    post retry_chat_url(chat)

    assert_redirected_to chat_path(chat)
    assert turn.reload.pending?
    assert_enqueued_with job: AssistantResponseJob, args: [ turn ]
  end

  test "retry is refused while a turn runs" do
    chat = chats(:one)
    chat.ask!("Question", ai_model: "gpt-4.1")
    clear_enqueued_jobs

    post retry_chat_url(chat)

    assert_redirected_to chat_path(chat)
    assert_equal I18n.t("chats.retry.in_progress"), flash[:alert]
    assert_no_enqueued_jobs
  end

  test "cannot retry if AI is disabled" do
    @user.update!(ai_enabled: false)

    post retry_chat_url(chats(:one))

    assert_response :forbidden
  end

  test "shows chat" do
    get chat_url(chats(:one))
    assert_response :success
  end

  test "destroys chat" do
    assert_difference("Chat.count", -1) do
      delete chat_url(chats(:one))
    end

    assert_redirected_to chats_url
  end

  test "should not allow access to other user's chats" do
    other_user = users(:family_member)
    other_chat = Chat.create!(user: other_user, title: "Other User's Chat")

    get chat_url(other_chat)
    assert_response :not_found

    delete chat_url(other_chat)
    assert_response :not_found
  end

  # --- "Dig in with AI" (w3-reports insights-feed) ---

  test "a new chat from an insight has its facts in the message box" do
    insight = @user.family.insights.create!(
      kind: "idle_cash", dedupe_key: "a", period_start: Date.current.beginning_of_month, priority: "low",
      template_key: "idle_cash", facts: { account: "Savings", balance: "$5,000.00", idle_days: 60 },
      metadata: {}, generated_at: Time.current
    )

    assert_no_difference("Chat.count") do
      get new_chat_url(insight_id: insight.id)
    end

    assert_response :success
    assert_select "textarea[name='chat[content]'][autofocus]", text: /Idle cash in Savings/
    assert_select "textarea[name='chat[content]']", text: /Balance: \$5,000\.00/
  end

  test "a new chat ignores another family's insight" do
    insight = families(:empty).insights.create!(
      kind: "idle_cash", dedupe_key: "a", priority: "low", template_key: "idle_cash",
      facts: { account: "Elsewhere", balance: "$1.00", idle_days: 60 }, generated_at: Time.current
    )

    get new_chat_url(insight_id: insight.id)

    assert_response :success
    assert_select "textarea[name='chat[content]']", text: ""
  end

  private
    # A self-hosted instance with no OpenAI key and no Claude bridge
    def without_ai_engine
      previous = Setting.openai_access_token
      Setting.openai_access_token = nil

      with_self_hosting do
        with_env_overrides OPENAI_ACCESS_TOKEN: nil, CLAUDE_BRIDGE_URL: nil, CLAUDE_BRIDGE_TOKEN: nil do
          yield
        end
      end
    ensure
      Setting.openai_access_token = previous
    end
end
