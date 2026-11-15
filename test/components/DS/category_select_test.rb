require "test_helper"

class DS::CategorySelectTest < ViewComponent::TestCase
  setup do
    @family = families(:dylan_family)
    @salary = @family.categories.create!(name: "Salary", color: "#22c55e", classification: "income", lucide_icon: "briefcase")
    @bonus = @family.categories.create!(name: "Bonus", color: "#22c55e", classification: "income", lucide_icon: "gift", parent: @salary)
  end

  test "lists parents with their subcategories under them" do
    render_select(categories: [ @salary, @bonus ])

    names = page.all("[data-category-select-target=option]", visible: :all).map { |option| option["data-category-name"] }
    assert_equal [ "Salary", "Bonus" ], names
    assert_selector "[data-category-id='#{@bonus.id}'] [data-testid=category-select-subcategory-indicator]", visible: :all
  end

  test "carries the form's classification for an inline create" do
    render_select(categories: [ @salary ], classification: "income")

    assert_selector "[data-controller=category-select][data-category-select-classification-value=income]"
  end

  test "an unknown classification falls back to expense" do
    render_select(categories: [], classification: "transfer")

    assert_selector "[data-category-select-classification-value=expense]"
  end

  test "offers only top-level parents of the form's classification" do
    expense_parent = categories(:food_and_drink)

    render_select(categories: [ @salary, @bonus, expense_parent ], classification: "income")

    parent_ids = page.all("[data-category-select-target=parentOption]", visible: :all).map { |row| row["data-parent-id"] }
    assert_equal [ @salary.id ], parent_ids
  end

  test "shows the recent categories in their own group" do
    render_select(categories: [ @salary, @bonus ], recent_categories: [ @bonus ])

    assert_selector "[data-category-select-target=recentSection] [data-category-id='#{@bonus.id}']", visible: :all
    assert_selector "[data-category-select-target=recentSection]", text: I18n.t("ds.category_select.recent"), visible: :all
  end

  test "has no recent group without recent categories" do
    render_select(categories: [ @salary ])

    assert_no_selector "[data-category-select-target=recentSection]", visible: :all
  end

  test "the trigger shows the selected category and the hidden field its id" do
    render_select(categories: [ @salary, @bonus ], selected_id: @bonus.id)

    assert_selector "button[data-category-select-target=button]", text: "Bonus"
    assert_selector "input[type=hidden][name='transaction[category_id]'][value='#{@bonus.id}']", visible: :all
  end

  test "the blank row is an Uncategorized badge" do
    render_select(categories: [ @salary ], blank_label: "Select a Category")

    assert_selector "[data-category-id=''][data-category-name='#{Category.uncategorized_name}']", visible: :all
    assert_selector "button[data-category-select-target=button]", text: "Select a Category"
  end

  test "creatable: false renders no create rows or parent picker" do
    render_select(categories: [ @salary ], creatable: false)

    assert_selector "[data-category-select-locked-value=true]"
    assert_no_selector "[data-category-select-target=createAsSubcategory]", visible: :all
    assert_no_selector "[data-category-select-target=parentPicker]", visible: :all
  end

  test "the label points at the trigger, whose id is scoped by the form" do
    render_select(categories: [ @salary ])

    assert_selector "label[for=transaction_category_id_trigger]"
    assert_selector "button#transaction_category_id_trigger"
  end

  test "a disabled select submits nothing and has no menu" do
    render_select(categories: [ @salary ], selected_id: @salary.id, disabled: true)

    assert_selector "input[type=hidden][disabled]", visible: :all
    assert_no_selector "[data-category-select-target=menu]", visible: :all
  end

  private
    def render_select(**options)
      with_request_url "/" do
        render_inline(DS::CategorySelect.new(form: form_builder, **options))
      end
    end

    def form_builder
      StyledFormBuilder.new(:transaction, Transaction.new, vc_test_controller.view_context, {})
    end
end
