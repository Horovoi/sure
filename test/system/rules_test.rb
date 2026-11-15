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
