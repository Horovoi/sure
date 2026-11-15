require "test_helper"

class Settings::AiChatsControllerTest < ActionDispatch::IntegrationTest
  BRIDGE_URL = "http://claude-bridge.test:3339".freeze
  BRIDGE_TOKEN = ("b" * 40).freeze

  setup do
    @user = users(:family_admin)
    @user.family.update!(timezone: "Europe/Kyiv")
    sign_in @user
    Setting.chat_model = nil
  end

  teardown do
    Setting.chat_model = nil
  end

  test "the card shows the account, plan and usage windows in Kyiv time" do
    stub_health(ok: true, signed_in: true, plan: "max", cli_version: "2.1.325",
      account: { email: "owner@example.com", plan: "max" },
      usage: { available: true, five_hour: { utilization: 0.42, resets_at: "2026-11-15T12:20:00Z" },
                seven_day: { utilization: 0.95, resets_at: "2026-11-18T08:00:00Z" } })
    stub_models

    with_bridge { get settings_ai_chat_path }

    assert_response :success
    assert_select "turbo-frame#claude_card"
    assert_select "[data-testid=claude-bridge-up]"
    assert_includes response.body, "owner@example.com"
    assert_includes response.body, "42% used"
    assert_includes response.body, "Nov 15, 14:20"
    assert_includes response.body, "95% used"
    assert_select "[data-testid=claude-usage-seven_day] .bg-destructive"
    assert_select "select[name='ai_chat[chat_model]'] option[value=opus]"
  end

  test "the card shows the start command when the bridge is down" do
    stub_request(:get, "#{BRIDGE_URL}/health").to_raise(Errno::ECONNREFUSED)
    stub_request(:get, "#{BRIDGE_URL}/models").to_raise(Errno::ECONNREFUSED)

    with_bridge { get settings_ai_chat_path }

    assert_response :success
    assert_select "[data-testid=claude-bridge-down]"
    assert_includes response.body, "bin/claude-bridge run"
    # The fallback aliases still fill the select
    assert_select "select[name='ai_chat[chat_model]'] option[value=sonnet]"
  end

  test "the card explains how to turn the Claude chat on when it is not configured" do
    with_env_overrides(CLAUDE_BRIDGE_URL: nil, CLAUDE_BRIDGE_TOKEN: nil) { get settings_ai_chat_path }

    assert_response :success
    assert_select "[data-testid=claude-not-configured]"
  end

  test "an admin saves a Claude model and new chats use it" do
    stub_models

    with_bridge do
      patch settings_ai_chat_path, params: { ai_chat: { chat_model: "opus" } }

      assert_redirected_to settings_ai_prompts_path
      assert_equal "opus", Setting.chat_model
      assert_equal "opus", Chat.default_model
    end
  end

  test "blank means automatic: sonnet with the bridge, OpenAI without" do
    Setting.chat_model = "opus"
    stub_models

    with_bridge do
      patch settings_ai_chat_path, params: { ai_chat: { chat_model: "" } }

      assert_nil Setting.chat_model
      assert_equal "sonnet", Chat.default_model
    end

    with_env_overrides(CLAUDE_BRIDGE_URL: nil, CLAUDE_BRIDGE_TOKEN: nil) do
      assert_equal Chat.openai_model, Chat.default_model
    end
  end

  test "a model that is not offered is refused" do
    stub_models

    with_bridge { patch settings_ai_chat_path, params: { ai_chat: { chat_model: "gpt-evil" } } }

    assert_redirected_to settings_ai_prompts_path
    assert_nil Setting.chat_model
    assert_equal I18n.t("settings.ai_chats.update.invalid_model"), flash[:alert]
  end

  test "a member who is not an admin cannot change the model" do
    sign_in users(:family_member)
    stub_models

    with_bridge { patch settings_ai_chat_path, params: { ai_chat: { chat_model: "opus" } } }

    assert_redirected_to settings_ai_prompts_path
    assert_nil Setting.chat_model
  end

  test "a saved Claude model falls back to OpenAI when the bridge is not configured" do
    Setting.chat_model = "opus"

    with_env_overrides(CLAUDE_BRIDGE_URL: nil, CLAUDE_BRIDGE_TOKEN: nil) do
      assert_equal Chat.openai_model, Chat.default_model
    end
  end

  private
    def with_bridge(&block)
      with_env_overrides(CLAUDE_BRIDGE_URL: BRIDGE_URL, CLAUDE_BRIDGE_TOKEN: BRIDGE_TOKEN, &block)
    end

    def stub_health(**body)
      stub_request(:get, "#{BRIDGE_URL}/health").to_return(status: 200, body: body.to_json + "\n")
    end

    def stub_models
      stub_request(:get, "#{BRIDGE_URL}/models").to_return(status: 200, body: {
        models: [ { value: "opus", display_name: "Opus" }, { value: "sonnet", display_name: "Sonnet" }, { value: "haiku", display_name: "Haiku" } ]
      }.to_json + "\n")
    end
end
