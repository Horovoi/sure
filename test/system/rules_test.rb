require "application_system_test_case"

class RulesTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.rules.destroy_all
    @first = create_rule("First rule")
    @second = create_rule("Second rule")

    sign_in @user
  end

  test "reorder rules with the keyboard and keep the order after a reload" do
    visit rules_path

    assert_equal [ @first.id, @second.id ], listed_rule_ids

    # Grab the second rule, move it up and drop it, as a keyboard user would
    item = find("[data-section-key='#{@second.id}']")
    execute_script("arguments[0].focus()", item)
    page.send_keys(:enter)
    page.send_keys(:up)
    page.send_keys(:enter)

    # The save is asynchronous; wait for the stored order
    assert_eventually { @family.rules.ordered.pluck(:id) == [ @second.id, @first.id ] }

    visit rules_path
    assert_equal [ @second.id, @first.id ], listed_rule_ids
  end

  test "a rule set to stop processing shows the badge" do
    @first.update!(stop_processing: true)

    visit rules_path

    within "##{ActionView::RecordIdentifier.dom_id(@first)}" do
      assert_text I18n.t("rules.rule.stop_processing")
    end
    within "##{ActionView::RecordIdentifier.dom_id(@second)}" do
      assert_no_text I18n.t("rules.rule.stop_processing")
    end
  end

  test "a valueless operator hides the value field and the rule saves with it" do
    visit edit_rule_path(@first)

    operator = find("select[name='rule[conditions_attributes][0][operator]']")
    value_field = find("[data-rule--conditions-target='filterValue']", match: :first)

    operator.select I18n.t("rules.condition_filters.operators.is_not_empty")
    assert value_field.matches_css?(".hidden", wait: 2)

    operator.select I18n.t("rules.condition_filters.operators.starts_with")
    assert value_field.not_matches_css?(".hidden", wait: 2)

    operator.select I18n.t("rules.condition_filters.operators.is_not_empty")
    operator.ancestor("form").find("[type='submit']").click

    assert_eventually { @first.reload.conditions.first.operator == "is_not_null" }
    assert_nil @first.conditions.first.value.presence
  end

  test "the tag condition offers the family's tags and the select operators" do
    @family.tags.create!(name: "Work trip")
    visit edit_rule_path(@first)

    find("select[name='rule[conditions_attributes][0][condition_type]']").select "Transaction tag"

    operator_options = find("select[name='rule[conditions_attributes][0][operator]']").all("option").map(&:text)
    assert_includes operator_options, I18n.t("rules.condition_filters.operators.not_equal_to")
    assert_includes operator_options, I18n.t("rules.condition_filters.operators.is_not_empty")
    assert_includes find("select[name='rule[conditions_attributes][0][value]']").all("option").map(&:text), "Work trip"
  end

  test "a tag action takes several tags from the tag picker" do
    work = @family.tags.create!(name: "Work trip")
    travel = @family.tags.create!(name: "Travel spend")
    visit edit_rule_path(@first)

    action_type = find("select[name='rule[actions_attributes][0][action_type]']")
    action_type.select "Set transaction tags"

    action_row = action_type.ancestor("[data-controller~='rule--actions']")
    within action_row do
      find("[data-tag-select-target='button']").click
      find("[data-tag-select-target='option'][data-tag-name='Work trip']").click
      find("[data-tag-select-target='option'][data-tag-name='Travel spend']").click
    end

    action_type.ancestor("form").find("[type='submit']").click

    assert_eventually do
      action = @first.reload.actions.first
      action.action_type == "set_transaction_tags" && action.execution_value.sort == [ work.id, travel.id ].sort
    end

    action = @first.reload.actions.first
    assert_equal "set_transaction_tags", action.action_type
    assert_equal [ work.id, travel.id ].sort, action.execution_value.sort
  end

  private
    def create_rule(name)
      @family.rules.create!(
        name: name,
        resource_type: "transaction",
        active: true,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: name) ],
        actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
      )
    end

    def listed_rule_ids
      all("#rules_list [data-section-key]").map { |node| node["data-section-key"] }
    end

    def assert_eventually(timeout: Capybara.default_max_wait_time)
      deadline = Time.current + timeout
      until yield
        flunk "condition not met within #{timeout}s" if Time.current > deadline
        sleep 0.1
      end
    end
end
