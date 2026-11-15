require "test_helper"

class Assistant::Function::TagToolsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @create = Assistant::Function::CreateTag.new(@user)
    @update = Assistant::Function::UpdateTag.new(@user)
  end

  test "create_tag makes a tag with a palette color" do
    result = nil
    assert_difference -> { @family.tags.count }, 1 do
      result = @create.call("name" => "Vacation 2027")
    end

    tag = Tag.find(result[:id])
    assert result[:created]
    assert_includes Tag::COLORS, tag.color
  end

  test "create_tag returns an existing name without a second tag" do
    assert_no_difference -> { Tag.count } do
      result = @create.call("name" => "Trips")
      assert_equal false, result[:created]
      assert_equal tags(:one).id, result[:id]
    end
  end

  test "create_tag refuses blank names and bad colors" do
    assert_equal "invalid_name", @create.call("name" => "")[:error]
    assert_equal "invalid_color", @create.call("name" => "Blue", "color" => "blue")[:error]
  end

  test "update_tag finds a tag by id or exact name" do
    @update.call("id" => tags(:one).id, "new_name" => "Travel")
    assert_equal "Travel", tags(:one).reload.name

    result = @update.call("name" => "Emergency fund", "color" => "#abcdef")
    assert_equal tags(:two).id, result[:id]
    assert_equal "#abcdef", tags(:two).reload.color
  end

  test "update_tag audits the state before and is an idempotent write" do
    before = @update.audit_before("id" => tags(:one).id)

    assert_equal({ id: tags(:one).id, name: "Trips", color: tags(:one).color }, before)
    assert_equal :write, @update.scope_tag
    assert @update.idempotent?
  end

  test "update_tag refuses another family's tag and empty calls" do
    assert_equal "not_found", @update.call("id" => tags(:three).id, "new_name" => "Mine")[:error]
    assert_equal "not_found", @update.call("name" => "Test", "new_name" => "Mine")[:error]
    assert_equal "not_found", @update.call({})[:error]
    assert_equal "no_changes", @update.call("id" => tags(:one).id)[:error]
  end

  test "the update_tag schema holds no family data" do
    assert_not_includes @update.params_schema.to_json, "Trips"
  end
end
