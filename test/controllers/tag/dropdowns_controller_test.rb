require "test_helper"

class Tag::DropdownsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:transaction)
  end

  test "lists the family's tags and marks the transaction's own" do
    tag = @user.family.tags.first
    @entry.transaction.update!(tag_ids: [ tag.id ])

    get tag_dropdown_url(entry_id: @entry.id)

    assert_response :success
    assert_select "turbo-frame#tag_dropdown"
    assert_select "##{ActionView::RecordIdentifier.dom_id(@entry, :tag_option)}_#{tag.id}[aria-selected=true]"
    @user.family.tags.where.not(id: tag.id).each do |other|
      assert_select "##{ActionView::RecordIdentifier.dom_id(@entry, :tag_option)}_#{other.id}[aria-selected=false]"
    end
    assert_select "form[action='#{tags_transaction_path(@entry)}']"
  end
end
