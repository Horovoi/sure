require "test_helper"

class SessionTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:one)
  end

  test "set_preferred_tab stores an allowed key and value" do
    assert @session.set_preferred_tab("account_sidebar_tab", "all")

    assert_equal "all", @session.reload.get_preferred_tab("account_sidebar_tab")
  end

  test "set_preferred_tab ignores an unknown key" do
    assert_not @session.set_preferred_tab("custom_anything", "asset")

    assert_nil @session.reload.data["tab_preferences"]
  end

  test "set_preferred_tab ignores an unknown value" do
    assert_not @session.set_preferred_tab("account_sidebar_tab", "x" * 10_000)

    assert_nil @session.reload.get_preferred_tab("account_sidebar_tab")
  end

  test "get_preferred_tab ignores a stored value that is not allowed" do
    @session.update_column(:data, { "tab_preferences" => { "account_sidebar_tab" => "bogus" } })

    assert_nil @session.reload.get_preferred_tab("account_sidebar_tab")
  end
end
