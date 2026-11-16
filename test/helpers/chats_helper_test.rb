require "test_helper"

class ChatsHelperTest < ActionView::TestCase
  include InlineSvg::ActionView::Helpers
  include ChatsHelper

  test "each AI avatar copy has its own ids, and its references point at them" do
    first = ai_avatar_svg("ai.svg")
    second = ai_avatar_svg("ai.svg")

    first_ids = first.scan(/\bid="([^"]+)"/).flatten
    second_ids = second.scan(/\bid="([^"]+)"/).flatten

    assert_includes first_ids.join(" "), "paint0_linear_2942_1218-"
    assert_empty first_ids & second_ids

    references = first.scan(/url\(#([^)]+)\)/).flatten
    assert references.any?
    assert_empty references - first_ids
  end
end
