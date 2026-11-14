require "test_helper"

class NotifiableTest < ActiveSupport::TestCase
  setup do
    @controller = ApplicationController.new
  end

  test "a category rule CTA resolves with the symbol keys it was set with" do
    cta = { type: "category_rule", category_id: "1", category_name: "Food" }

    resolved = @controller.send(:resolve_cta, cta)

    assert_equal "rules/category_rule_cta", resolved[:partial]
    assert_equal "Food", resolved[:locals][:cta][:category_name]
  end

  test "a category rule CTA resolves with the string keys it has after a redirect" do
    cta = { "type" => "category_rule", "category_id" => "1", "category_name" => "Food" }

    resolved = @controller.send(:resolve_cta, cta)

    assert_equal "rules/category_rule_cta", resolved[:partial]
    assert_equal "Food", resolved[:locals][:cta][:category_name]
  end

  test "an unknown CTA resolves to nothing" do
    assert_nil @controller.send(:resolve_cta, { "type" => "other" })
    assert_nil @controller.send(:resolve_cta, "garbage")
  end
end
