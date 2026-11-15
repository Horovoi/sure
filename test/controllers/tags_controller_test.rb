require "test_helper"

class TagsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "should get index" do
    get tags_url
    assert_response :success

    @user.family.tags.each do |tag|
      assert_select "#" + dom_id(tag), count: 1
    end
  end

  test "should get new" do
    get new_tag_url
    assert_response :success
  end

  test "should create tag" do
    assert_difference("Tag.count") do
      post tags_url, params: { tag: { name: "Test Tag" } }
    end

    assert_redirected_to tags_url
    assert_equal "Tag created", flash[:notice]
  end

  test "should get edit" do
    get edit_tag_url(tags.first)
    assert_response :success
  end

  test "should update tag" do
    patch tag_url(tags.first), params: { tag: { name: "Test Tag" } }

    assert_redirected_to tags_url
    assert_equal "Tag updated", flash[:notice]
  end

  # --- DS pickers: inline create through the JSON endpoint ---

  test "JSON create returns the new tag with its option markup" do
    assert_difference "Tag.count", +1 do
      post tags_url(format: :json), params: { tag: { name: "Holiday", color: Tag::COLORS.first } }, as: :json
    end

    assert_response :created
    body = response.parsed_body
    assert_equal "Holiday", body["name"]
    assert_includes body["html"], %(data-tag-id="#{body["id"]}")
  end

  test "JSON create returns the validation errors" do
    existing = users(:family_admin).family.tags.first

    assert_no_difference "Tag.count" do
      post tags_url(format: :json), params: { tag: { name: existing.name, color: Tag::COLORS.first } }, as: :json
    end

    assert_response :unprocessable_entity
    assert response.parsed_body["errors"].any?
  end
end
