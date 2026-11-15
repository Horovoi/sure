require "test_helper"

class DS::TagSelectTest < ViewComponent::TestCase
  test "marks the selected tags and always sends an empty value" do
    render_select(tags: [ tags(:one), tags(:two) ], selected_ids: [ tags(:one).id ])

    assert_selector "[data-tag-select-target=option][data-tag-id='#{tags(:one).id}'][aria-selected=true]", visible: :all
    assert_selector "[data-tag-select-target=option][data-tag-id='#{tags(:two).id}'][aria-selected=false]", visible: :all
    # The blank value lets a form clear every tag.
    assert_selector "[data-tag-select-hidden-inputs] input[type=hidden][name='transaction[tag_ids][]'][value='']", visible: :all
  end

  test "posts new tags to the JSON create endpoint and saves through update_url" do
    render_select(tags: [], selected_ids: [], auto_submit: true, update_url: "/transactions/1/tags")

    assert_selector "[data-tag-select-create-url-value='/tags.json'][data-tag-select-update-url-value='/transactions/1/tags'][data-tag-select-auto-submit-value=true]"
  end

  test "carries localized error messages for the controller" do
    render_select(tags: [], selected_ids: [])

    assert_selector "[data-tag-select-error-message-value=\"#{I18n.t("ds.tag_select.create_error")}\"]"
    assert_selector "[data-tag-select-save-error-message-value=\"#{I18n.t("ds.tag_select.save_error")}\"]"
  end

  test "without a visible label the trigger is named by the label text" do
    render_select(tags: [], selected_ids: [], show_label: false, label: "Tags")

    assert_no_selector "label"
    assert_selector "button[aria-label=Tags]"
  end

  private
    def render_select(**options)
      with_request_url "/" do
        render_inline(DS::TagSelect.new(form: form_builder, **options))
      end
    end

    def form_builder
      StyledFormBuilder.new(:transaction, Transaction.new, vc_test_controller.view_context, {})
    end
end
