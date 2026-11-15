require "test_helper"

class FilterParameterLoggingTest < ActiveSupport::TestCase
  setup do
    @filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
  end

  test "one-time codes and OAuth credentials are filtered" do
    filtered = @filter.filter(
      "code" => "123456",
      "invite_code" => "abc123",
      "code_verifier" => "verifier",
      "code_challenge" => "challenge",
      "oauth_access_token" => "access",
      "oauth_refresh_token" => "refresh"
    )

    filtered.each do |key, value|
      assert_equal "[FILTERED]", value, "#{key} should be filtered"
    end
  end

  test "a nested MFA code is filtered" do
    filtered = @filter.filter("mfa" => { "code" => "123456" })

    assert_equal "[FILTERED]", filtered.dig("mfa", "code")
  end

  test "code-like attributes that are not credentials stay readable" do
    filtered = @filter.filter("currency_code" => "UAH", "country_code" => "UA")

    assert_equal "UAH", filtered["currency_code"]
    assert_equal "UA", filtered["country_code"]
  end
end
