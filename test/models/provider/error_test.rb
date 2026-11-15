require "test_helper"

class Provider::ErrorTest < ActiveSupport::TestCase
  test "carries a failure code" do
    error = Provider::Error.new("Too many requests", details: { "x" => 1 }, failure_code: :rate_limited)

    assert_equal :rate_limited, error.failure_code
    assert_equal({ message: "Too many requests", details: { "x" => 1 }, failure_code: :rate_limited }, error.as_json)
  end

  test "failure code is optional" do
    error = Provider::Error.new("Boom")

    assert_nil error.failure_code
    assert_nil error.as_json[:failure_code]
  end
end
