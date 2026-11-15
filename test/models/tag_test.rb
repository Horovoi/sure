require "test_helper"

class TagTest < ActiveSupport::TestCase
  test "replace and destroy" do
    old_tag = tags(:one)
    new_tag = tags(:two)

    assert_difference "Tag.count", -1 do
      old_tag.replace_and_destroy!(new_tag)
    end

    old_tag.transactions.each do |txn|
      txn.reload
      assert_includes txn.tags, new_tag
      assert_not_includes txn.tags, old_tag
    end
  end

  test "color must be a six-digit hex value" do
    tag = families(:empty).tags.build(name: "Colour check")

    tag.color = "#12ab34"
    assert tag.valid?

    tag.color = nil
    assert tag.valid?

    tag.color = "red"
    assert_not tag.valid?
    assert tag.errors.of_kind?(:color, :invalid)
  end

  test "an existing tag with an old non-hex colour can still be renamed" do
    tag = tags(:three)
    tag.update_column(:color, "red")

    assert tag.update(name: "Renamed")
  end
end
