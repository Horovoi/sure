require "application_system_test_case"

class Settings::ClaudeCardTest < ApplicationSystemTestCase
  BRIDGE_URL = "http://claude-bridge.test:3339".freeze
  BRIDGE_TOKEN = ("b" * 40).freeze

  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)
    @user.family.update!(timezone: "Europe/Kyiv")
    Setting.chat_model = nil
    stub_request(:get, "#{BRIDGE_URL}/models").to_return(status: 200, body: {
      models: [ { value: "opus", display_name: "Opus" }, { value: "sonnet", display_name: "Sonnet" } ]
    }.to_json + "\n")
    login_as @user
  end

  teardown do
    Setting.chat_model = nil
  end

  test "the Claude card shows the account and usage while the bridge runs, and the model select saves" do
    stub_request(:get, "#{BRIDGE_URL}/health").to_return(status: 200, body: {
      ok: true, signed_in: true, plan: "max", cli_version: "2.1.325", account: { email: "owner@example.com" },
      usage: { available: true, five_hour: { utilization: 0.3, resets_at: 2.hours.from_now.utc.iso8601 },
               seven_day: { utilization: 0.6, resets_at: 3.days.from_now.utc.iso8601 } }
    }.to_json + "\n")

    with_bridge do
      visit settings_ai_prompts_path

      within_testid("claude-card") do
        assert_text I18n.t("settings.ai_prompts.claude_card.bridge_up")
        assert_text "owner@example.com"
        assert_text I18n.t("settings.ai_prompts.claude_card.windows.five_hour")
        assert_text "30% used"
        assert_text "60% used"

        select "Opus", from: I18n.t("settings.ai_prompts.claude_card.model_label")
      end

      assert_text I18n.t("settings.ai_chats.update.saved")
      assert_equal "opus", Setting.chat_model
    end
  end

  test "the Claude card says how to start the bridge when it is down" do
    stub_request(:get, "#{BRIDGE_URL}/health").to_raise(Errno::ECONNREFUSED)

    with_bridge do
      visit settings_ai_prompts_path

      within_testid("claude-card") do
        assert_text I18n.t("settings.ai_prompts.claude_card.bridge_down")
        assert_text "bin/claude-bridge run"
      end
    end
  end

  private
    def with_bridge(&block)
      with_env_overrides(CLAUDE_BRIDGE_URL: BRIDGE_URL, CLAUDE_BRIDGE_TOKEN: BRIDGE_TOKEN, &block)
    end
end
