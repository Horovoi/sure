require "test_helper"

class DS::SelectTest < ViewComponent::TestCase
  test "child? is true for an item whose object has a present parent_id" do
    select = DS::Select.new(form: nil, method: :category_id, items: [ categories(:subcategory) ])

    assert select.child?(select.items.first)
  end

  test "child? is false for an item whose object has no parent_id" do
    select = DS::Select.new(form: nil, method: :category_id, items: [ categories(:food_and_drink) ])

    assert_not select.child?(select.items.first)
  end

  test "child? is false for objects that don't respond to parent_id" do
    select = DS::Select.new(form: nil, method: :merchant_id, items: [ merchants(:netflix) ])

    assert_not select.child?(select.items.first)
  end

  test "child? is false for the include_blank placeholder item" do
    select = DS::Select.new(
      form: nil,
      method: :category_id,
      items: [ categories(:subcategory) ],
      include_blank: "Uncategorized"
    )

    blank_item = select.items.first
    assert_nil blank_item[:object]
    assert_not select.child?(blank_item)
  end

  test "the logo variant falls back to a lettermark on the closed trigger" do
    account = accounts(:depository)

    render_select(variant: :logo, items: [ account ], selected: account.id)

    assert_selector "button[data-select-target=button] [data-select-logo]"
    assert_no_selector "button[data-select-target=button] img"
  end

  test "the simple variant keeps a plain-text trigger" do
    account = accounts(:depository)

    render_select(variant: :simple, items: [ account ], selected: account.id)

    assert_no_selector "button[data-select-target=button] [data-select-logo]"
    assert_selector "button[data-select-target=button]", text: account.name
  end

  test "a disabled select shows its value without a submitted field" do
    account = accounts(:depository)

    render_select(variant: :logo, items: [ account ], selected: account.id, disabled: true)

    assert_selector "button[data-select-target=button][disabled] [data-select-logo]"
    assert_no_selector "input[type=hidden][name='transfer_match[account_id]']", visible: :all
  end

  test "the hidden field carries the selected value for the form" do
    account = accounts(:depository)

    render_select(items: [ account ], selected: account.id)

    assert_selector "input[type=hidden][name='transfer_match[account_id]'][value='#{account.id}']", visible: :all
  end

  test "falls back to the placeholder, not the include_blank item's own label, when nothing is selected" do
    render_inline DS::Select.new(
      form: form_builder_for(Category.new, "category"),
      method: :parent_id,
      items: [ { value: 1, label: "Groceries" } ],
      selected: nil,
      placeholder: "Select a Category",
      include_blank: "(none)"
    )

    assert_selector "button#parent_id_trigger", text: "Select a Category"
    refute_selector "button#parent_id_trigger", text: "(none)"
  end

  test "shows the selected item's label when a real item is selected" do
    render_inline DS::Select.new(
      form: form_builder_for(Category.new, "category"),
      method: :parent_id,
      items: [ { value: 1, label: "Groceries" } ],
      selected: 1,
      placeholder: "Select a Category",
      include_blank: "(none)"
    )

    assert_selector "button#parent_id_trigger", text: "Groceries"
  end

  test "the default placeholder and search text come from the ds.select keys" do
    render_inline DS::Select.new(
      form: form_builder_for(Category.new, "category"),
      method: :parent_id,
      items: [ { value: 1, label: "Groceries" } ],
      searchable: true
    )

    assert_selector "button#parent_id_trigger", text: I18n.t("ds.select.default_label")
    assert_selector "input[type=search][placeholder='#{I18n.t("ds.select.search_placeholder")}']", visible: :all
    assert_selector "[data-controller~='list-filter']"
  end

  test "subcategory rows are indented in the menu" do
    render_inline DS::Select.new(
      form: form_builder_for(Transaction.new, "transaction"),
      method: :category_id,
      items: [ categories(:food_and_drink), categories(:subcategory) ],
      variant: :badge
    )

    assert_selector "[role=option][data-value='#{categories(:subcategory).id}'] svg", visible: :all
    assert_selector "[role=option]", count: 2, visible: :all
  end

  private
    def render_select(**options)
      with_request_url "/" do
        render_inline(DS::Select.new(form: form_builder, method: :account_id, **options))
      end
    end

    def form_builder
      ActionView::Helpers::FormBuilder.new(:transfer_match, nil, vc_test_controller.view_context, {})
    end

    def form_builder_for(object, name)
      StyledFormBuilder.new(name, object, vc_test_controller.view_context, {})
    end
end
