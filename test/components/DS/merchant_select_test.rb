require "test_helper"

class DS::MerchantSelectTest < ViewComponent::TestCase
  test "lists the merchants with a blank row and posts to the JSON create endpoint" do
    render_select(merchants: [ merchants(:netflix), merchants(:amazon) ], include_blank: "(none)")

    assert_selector "[data-merchant-select-create-url-value='/family_merchants.json']"
    assert_selector "[data-merchant-select-target=option]", count: 3, visible: :all
    assert_selector "[data-merchant-select-target=option][data-merchant-id='']", visible: :all
  end

  test "the trigger shows the selected merchant and the hidden field its id" do
    merchant = merchants(:netflix)

    render_select(merchants: [ merchant ], selected_id: merchant.id)

    assert_selector "button[data-merchant-select-target=button]", text: merchant.name
    assert_selector "input[type=hidden][name='transaction[merchant_id]'][value='#{merchant.id}']", visible: :all
  end

  test "the trigger shows the blank text without a selection" do
    render_select(merchants: [ merchants(:netflix) ], include_blank: "(none)")

    assert_selector "button[data-merchant-select-target=button]", text: "(none)"
  end

  test "the label defaults to the ds key" do
    render_select(merchants: [])

    assert_selector "label", text: I18n.t("ds.merchant_select.label")
  end

  test "the create row names the typed merchant through the localized text" do
    render_select(merchants: [])

    assert_selector "[data-merchant-select-target=createForm] [data-merchant-select-create-name]", visible: :all
  end

  private
    def render_select(selected_id: nil, **options)
      with_request_url "/" do
        render_inline(DS::MerchantSelect.new(form: form_builder, method: :merchant_id, selected_id: selected_id, **options))
      end
    end

    def form_builder
      StyledFormBuilder.new(:transaction, Transaction.new, vc_test_controller.view_context, {})
    end
end
