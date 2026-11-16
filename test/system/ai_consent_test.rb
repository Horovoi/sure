require "application_system_test_case"

# The AI box over the chat sidebar (on a phone, the Assistant page) while the user's AI switch is off:
# with no AI engine it says how to connect one; with an engine it offers to turn AI on.
class AiConsentTest < ApplicationSystemTestCase
  PHONE = [ 390, 844 ].freeze
  SHOTS = ENV["AI_CONSENT_SHOTS"].presence

  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: false, show_ai_sidebar: true)
    @previous_token = Setting.openai_access_token
    Setting.openai_access_token = nil
  end

  teardown do
    Setting.openai_access_token = @previous_token
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end

  test "with no AI engine the sidebar says how to connect one and links to the AI settings" do
    with_no_engine do
      login_as @user

      within "#chat-container" do
        assert_selector "h3", text: I18n.t("chats.ai_consent.setup_title")
        assert_text I18n.t("chats.ai_consent.claude_body")
        assert_text I18n.t("chats.ai_consent.openai_body")
        assert_no_text "OPENAI_ACCESS_TOKEN"
        assert_no_button I18n.t("chats.ai_consent.enable_button")
      end

      shoot("desktop-setup")
      within("#chat-container") { click_on I18n.t("chats.ai_consent.setup_button") }

      assert_current_path settings_ai_prompts_path
      assert_selector "[data-testid=openai-status]", text: I18n.t("settings.ai_prompts.show.openai_key.not_connected")
      assert_link I18n.t("settings.ai_prompts.show.openai_key.add_link"), href: settings_hosting_path
      shoot("desktop-settings")
    end
  end

  test "with an AI engine the sidebar offers to turn AI on" do
    with_no_engine do
      with_env_overrides CLAUDE_BRIDGE_URL: "http://host.docker.internal:3339", CLAUDE_BRIDGE_TOKEN: "t" * 40 do
        login_as @user

        within "#chat-container" do
          assert_selector "h3", text: I18n.t("chats.ai_consent.enable_title")
          assert_no_text I18n.t("chats.ai_consent.setup_title")
        end

        shoot("desktop-enable")
        within("#chat-container") { click_on I18n.t("chats.ai_consent.enable_button") }

        assert_selector "h1", text: "Welcome back, #{@user.first_name}"
        assert @user.reload.ai_enabled
        within("#chat-container") { assert_no_selector "[data-testid=ai-consent]" }
      end
    end
  end

  test "on a phone the Assistant page shows the box instead of the chats" do
    with_no_engine do
      login_as @user
      # A desktop Chrome window does not get narrower than about 500px; the emulated screen does
      width, height = PHONE
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: true)
      visit chats_path

      assert_selector "[data-testid=ai-setup]", text: I18n.t("chats.ai_consent.setup_title")
      assert_no_selector "textarea[name='chat[content]']", visible: true
      shoot("phone-setup")

      click_on I18n.t("chats.ai_consent.setup_button")
      assert_current_path settings_ai_prompts_path
    end
  end

  private
    # A self-hosted instance with no OpenAI key and no Claude bridge
    def with_no_engine(&)
      with_self_hosting do
        with_env_overrides(OPENAI_ACCESS_TOKEN: nil, CLAUDE_BRIDGE_URL: nil, CLAUDE_BRIDGE_TOKEN: nil, &)
      end
    end

    # With AI_CONSENT_SHOTS=<dir>: the page in the light theme and in the dark theme (the user's theme
    # setting, so the page loads in it), then back to the theme the test started with
    def shoot(name)
      return unless SHOTS

      original = @user.reload.theme
      %w[light dark].each do |theme|
        @user.update!(theme: theme)
        page.refresh
        page.document.assert_selector theme == "dark" ? "html[data-theme='dark']" : "html:not([data-theme='dark'])", visible: :all
        sleep 0.5 # let the lazy frames and the blur settle
        page.save_screenshot(File.join(SHOTS, "ai-copy-#{name}-#{theme}.png"))
      end
      @user.update!(theme: original)
      page.refresh
    end
end
