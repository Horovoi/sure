require "test_helper"

class Assistant::Function::GetTagsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @fn = Assistant::Function::GetTags.new(@user)
  end

  test "has correct name and is not strict" do
    assert_equal "get_tags", @fn.name
    refute @fn.to_definition[:strict], "optional params need strict mode off"
  end

  test "lists the family's tags alphabetically with ids" do
    result = @fn.call

    assert_equal @user.family.tags.order(:name).pluck(:name), result[:tags].map { |t| t[:name] }
    assert(result[:tags].all? { |t| t[:id].present? })
    assert_not_includes result[:tags].map { |t| t[:id] }, tags(:three).id
  end

  test "pages with page_size" do
    result = @fn.call("page_size" => 1, "page" => 2)

    assert_equal 1, result[:tags].size
    assert_equal 2, result[:page]
    assert_equal @user.family.tags.count, result[:total_results]
  end
end
