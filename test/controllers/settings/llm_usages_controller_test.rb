require "test_helper"

class Settings::LlmUsagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    sign_in @user
  end

  test "shows the usage page with the pricing review date" do
    get settings_llm_usage_url

    assert_response :success
    assert_includes response.body, I18n.l(LlmUsage::PRICING_VERIFIED_ON, format: :long)
  end

  test "Claude subscription rows show their API-equivalent cost and stay out of the total" do
    @family.llm_usages.create!(provider: "openai", model: "gpt-4.1", operation: "chat", prompt_tokens: 100, completion_tokens: 50, total_tokens: 150, estimated_cost: 1.25)
    @family.llm_usages.create!(provider: LlmUsage::SUBSCRIPTION_PROVIDER, model: "claude-opus-5-5", operation: "chat", prompt_tokens: 1_000, completion_tokens: 500, total_tokens: 1_500, estimated_cost: 3.5)

    get settings_llm_usage_url

    assert_response :success
    assert_select "[data-testid='llm-total-cost']", text: "$1.25"
    assert_select "[data-testid='llm-subscription-cost']", text: /subscription \(API-equivalent \$3\.5000\)/
    assert_includes response.body, "API-equivalent $3.50"
  end

  test "a model without pricing shows N/A" do
    @family.llm_usages.create!(provider: "openai", model: "my-local-model", operation: "chat", prompt_tokens: 10, completion_tokens: 5, total_tokens: 15, estimated_cost: nil)

    get settings_llm_usage_url

    assert_response :success
    assert_includes response.body, "N/A"
  end
end
