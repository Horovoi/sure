require "test_helper"

class Assistant::Function::GetMerchantsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @fn = Assistant::Function::GetMerchants.new(@user)
  end

  test "has correct name and is not strict" do
    assert_equal "get_merchants", @fn.name
    refute @fn.to_definition[:strict]
  end

  test "lists the family's merchants alphabetically with ids and source" do
    result = @fn.call
    names = result[:merchants].map { |m| m[:name] }

    assert_includes names, "Amazon"
    assert_includes names, "Netflix"
    assert_equal names.sort, names
    assert_not_includes names, merchants(:one).name, "another family's merchant"
    assert_equal "family", result[:merchants].find { |m| m[:name] == "Amazon" }[:source]
  end

  test "search filters by a case-insensitive substring and treats LIKE wildcards literally" do
    assert_equal [ "Starbucks Coffee" ], @fn.call("search" => "starb")[:merchants].map { |m| m[:name] }
    assert_empty @fn.call("search" => "%")[:merchants]
  end

  test "pages with page_size" do
    result = @fn.call("page_size" => 1)

    assert_equal 1, result[:merchants].size
    assert_operator result[:total_pages], :>, 1
  end
end
