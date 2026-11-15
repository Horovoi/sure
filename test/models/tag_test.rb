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

  test "the database refuses a second tag with the same name in a family" do
    assert_raises ActiveRecord::RecordNotUnique do
      Tag.insert_all!([ { family_id: tags(:one).family_id, name: tags(:one).name, color: "#000000" } ])
    end
  end

  test "find_or_create_by_name! returns the existing tag or creates one" do
    family = tags(:one).family

    assert_equal tags(:one), family.tags.find_or_create_by_name!(tags(:one).name)

    created = nil
    assert_difference "Tag.count", +1 do
      created = family.tags.find_or_create_by_name!("Brand new") { |tag| tag.color = "#123456" }
    end
    assert created.previously_new_record?
    assert_equal "#123456", created.color
  end
end
