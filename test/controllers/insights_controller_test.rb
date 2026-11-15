require "test_helper"

class InsightsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @insight = create_insight(dedupe_key: "a", account: "Savings")
  end

  test "index lists the visible insights" do
    create_insight(dedupe_key: "b", account: "Hidden", dismissed_at: Time.current)

    get insights_path

    assert_response :success
    assert_select "#insights-list [data-testid=insight-row]", count: 1
    assert_select "#insights-list", text: /Idle cash in Savings/
  end

  test "dismiss hides the insight and offers an undo" do
    patch dismiss_insight_path(@insight), as: :turbo_stream

    assert_response :success
    assert @insight.reload.dismissed?
    assert_match "insight-undo-toast", response.body
    assert_match undismiss_insight_path(@insight), response.body
  end

  test "undo brings the insight back" do
    @insight.dismiss!

    patch undismiss_insight_path(@insight), as: :turbo_stream

    assert_response :success
    assert_not @insight.reload.dismissed?
  end

  test "dismiss without Turbo goes back to the list" do
    patch dismiss_insight_path(@insight)

    assert_redirected_to insights_path
    assert @insight.reload.dismissed?
  end

  test "another family's insight is not found" do
    other = families(:empty).insights.create!(kind: "idle_cash", dedupe_key: "x", priority: "low", template_key: "idle_cash",
                                               facts: { account: "X", balance: "$1", idle_days: 60 }, generated_at: Time.current)

    patch dismiss_insight_path(other), as: :turbo_stream

    assert_response :not_found
    assert_not other.reload.dismissed?
  end

  private
    def create_insight(dedupe_key:, account:, dismissed_at: nil)
      @family.insights.create!(
        kind: "idle_cash", dedupe_key: dedupe_key, period_start: Date.current.beginning_of_month, priority: "low",
        template_key: "idle_cash", facts: { account: account, balance: "$5,000.00", idle_days: 60 },
        metadata: {}, generated_at: Time.current, dismissed_at: dismissed_at
      )
    end
end
