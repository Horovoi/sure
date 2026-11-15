require "application_system_test_case"

class InsightsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @insight = @user.family.insights.create!(
      kind: "idle_cash", dedupe_key: "system", period_start: Date.current.beginning_of_month, priority: "low",
      template_key: "idle_cash", facts: { account: "Rainy day pot", balance: "$5,000.00", idle_days: 60 },
      metadata: {}, generated_at: Time.current
    )
  end

  test "Dig in with AI opens a new chat with the insight's facts in the message box" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token" do
      @user.update!(ai_enabled: true)
      login_as(@user)
      # The sidebar chat frame loads lazily. A late first load would replace the new
      # chat that Dig in opens, so wait for it first.
      assert_selector "turbo-frame#sidebar_chat[complete]", visible: :all

      within "#insights-feed" do
        assert_text "Idle cash in Rainy day pot"
        find("[data-testid=insight-dig-in]").click
      end

      within "#chat-container" do
        field = find("textarea[name='chat[content]']")
        assert_match "Idle cash in Rainy day pot", field.value
        assert_match "Balance: $5,000.00", field.value
      end

      # Nothing is sent until the user presses Enter
      assert_equal 0, @user.chats.where("title LIKE ?", "%Rainy day pot%").count
    end
  end

  test "dismissing an insight can be undone" do
    login_as(@user)

    within "#insights-feed" do
      click_on "Got it"
    end

    assert_text I18n.t("insights.feed.all_caught_up")

    within "[data-testid=insight-undo-toast]" do
      click_on "Undo"
    end

    within "#insights-feed" do
      assert_text "Idle cash in Rainy day pot"
    end
    assert_not @insight.reload.dismissed?
  end
end
