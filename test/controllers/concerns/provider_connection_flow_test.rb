require "test_helper"

class ProviderConnectionFlowTest < ActiveSupport::TestCase
  class Host < ActionController::Base
    include StoreLocation
    include ProviderConnectionFlow

    def self.with(params)
      new.tap { |host| host.params = ActionController::Parameters.new(params) }
    end

    def return_to = safe_return_to_path
    def target(default) = link_redirect_target(default)
  end

  test "keeps only paths inside the app" do
    assert_equal "/accounts/1", Host.with(return_to: "/accounts/1").return_to
    assert_nil Host.with(return_to: "https://evil.example/").return_to
    assert_nil Host.with(return_to: "//evil.example").return_to
    assert_nil Host.with({}).return_to
  end

  test "falls back to the default" do
    assert_equal "/accounts", Host.with(return_to: "https://evil.example/").target("/accounts")
    assert_equal "/settings", Host.with(return_to: "/settings").target("/accounts")
  end
end
