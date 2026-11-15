require "test_helper"

class RulesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "should get new" do
    get new_rule_url(resource_type: "transaction")
    assert_response :success
  end

  test "should get new with pre-filled name and action" do
    category = categories(:food_and_drink)
    get new_rule_url(
      resource_type: "transaction",
      name: "Starbucks",
      action_type: "set_transaction_category",
      action_value: category.id
    )
    assert_response :success

    assert_select "input[name='rule[name]'][value='Starbucks']"
    assert_select "input[name*='[value]'][value='Starbucks']"
    assert_select "select[name*='[condition_type]'] option[selected][value='transaction_name']"
    assert_select "select[name*='[action_type]'] option[selected][value='set_transaction_category']"
    assert_select "select[name*='[value]'] option[selected][value='#{category.id}']"
  end

  test "should get edit" do
    get edit_rule_url(rules(:one))
    assert_response :success
  end

  # "Set all transactions with a name like 'starbucks' and an amount between 20 and 40 to the 'food and drink' category"
  test "creates rule with nested conditions" do
    post rules_url, params: {
      rule: {
        effective_date: 30.days.ago.to_date,
        resource_type: "transaction",
        conditions_attributes: {
          "0" => {
            condition_type: "transaction_name",
            operator: "like",
            value: "starbucks"
          },
          "1" => {
            condition_type: "compound",
            operator: "and",
            sub_conditions_attributes: {
              "0" => {
                condition_type: "transaction_amount",
                operator: ">",
                value: 20
              },
              "1" => {
                condition_type: "transaction_amount",
                operator: "<",
                value: 40
              }
            }
          }
        },
        actions_attributes: {
          "0" => {
            action_type: "set_transaction_category",
            value: categories(:food_and_drink).id
          }
        }
      }
    }

    rule = @user.family.rules.order("created_at DESC").first

    # Rule
    assert_equal "transaction", rule.resource_type
    assert_not rule.active # Not active by default
    assert_equal 30.days.ago.to_date, rule.effective_date

    # Conditions assertions
    assert_equal 2, rule.conditions.count
    compound_condition = rule.conditions.find { |condition| condition.condition_type == "compound" }
    assert_equal "compound", compound_condition.condition_type
    assert_equal 2, compound_condition.sub_conditions.count

    # Actions assertions
    assert_equal 1, rule.actions.count
    assert_equal "set_transaction_category", rule.actions.first.action_type
    assert_equal categories(:food_and_drink).id, rule.actions.first.value

    assert_redirected_to confirm_rule_url(rule, reload_on_close: true)
  end

  test "can update rule" do
    rule = rules(:one)

    assert_difference -> { Rule.count } => 0,
      -> { Rule::Condition.count } => 1,
      -> { Rule::Action.count } => 1 do
      patch rule_url(rule), params: {
        rule: {
          active: false,
          conditions_attributes: {
            "0" => {
              id: rule.conditions.first.id,
              value: "new_value"
            },
            "1" => {
              condition_type: "transaction_amount",
              operator: ">",
              value: 100
            }
          },
          actions_attributes: {
            "0" => {
              id: rule.actions.first.id,
              value: "new_value"
            },
            "1" => {
              action_type: "set_transaction_tags",
              value: tags(:one).id
            }
          }
        }
      }
    end

    rule.reload

    assert_not rule.active
    assert_equal "new_value", rule.conditions.order("created_at ASC").first.value
    assert_equal "new_value", rule.actions.order("created_at ASC").first.value
    assert_equal tags(:one).id, rule.actions.order("created_at ASC").last.value
    assert_equal "100", rule.conditions.order("created_at ASC").last.value

    assert_redirected_to rules_url
  end

  test "can destroy conditions and actions while editing" do
    rule = rules(:one)

    assert_equal 1, rule.conditions.count
    assert_equal 1, rule.actions.count

    patch rule_url(rule), params: {
      rule: {
        conditions_attributes: {
          "0" => { id: rule.conditions.first.id, _destroy: true },
          "1" => {
            condition_type: "transaction_name",
            operator: "like",
            value: "new_condition"
          }
        },
        actions_attributes: {
          "0" => { id: rule.actions.first.id, _destroy: true },
          "1" => {
            action_type: "set_transaction_tags",
            value: tags(:one).id
          }
        }
      }
    }

    assert_redirected_to rules_url

    rule.reload

    assert_equal 1, rule.conditions.count
    assert_equal 1, rule.actions.count
  end

  test "can destroy rule" do
    rule = rules(:one)

    assert_difference [ "Rule.count", "Rule::Condition.count", "Rule::Action.count" ], -1 do
      delete rule_url(rule)
    end

    assert_redirected_to rules_url
  end

  test "should get confirm_all" do
    get confirm_all_rules_url
    assert_response :success
  end

  test "apply_all enqueues one ordered rule run and redirects" do
    assert_enqueued_with(job: ApplyRulesJob, args: [ @user.family, { execution_type: "manual", ignore_attribute_locks: true } ]) do
      post apply_all_rules_url
    end

    assert_redirected_to rules_url
  end

  test "index renders a rule with an empty compound condition" do
    rule = @user.family.rules.build(resource_type: "transaction")
    rule.conditions.build(condition_type: "compound", operator: "and")
    rule.actions.build(action_type: "exclude_transaction")
    rule.save!

    get rules_url

    assert_response :success
    assert_includes response.body, I18n.t("rules.no_condition")
  end

  test "index shows the next condition when the first compound condition is empty" do
    rule = @user.family.rules.build(resource_type: "transaction")
    rule.conditions.build(condition_type: "compound", operator: "and")
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "edge-case-name")
    rule.actions.build(action_type: "exclude_transaction")
    rule.save!

    get rules_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(rule)}" do
      assert_select "span", text: /edge-case-name/
      assert_select "span", text: /#{Regexp.escape(I18n.t("rules.no_condition"))}/, count: 0
      assert_select "p", text: /more condition/, count: 0
    end
  end

  test "index lists rules in run order with the stop badge" do
    family = @user.family
    family.rules.destroy_all
    second = family.rules.create!(name: "Second", resource_type: "transaction", actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    first = family.rules.create!(name: "First", resource_type: "transaction", stop_processing: true, actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    Rule.update_positions!(family, [ first.id, second.id ])

    get rules_url

    assert_response :success
    keys = css_select("#rules_list [data-section-key]").map { |node| node["data-section-key"] }
    assert_equal [ first.id, second.id ], keys
    assert_select "##{ActionView::RecordIdentifier.dom_id(first)}", text: /#{I18n.t("rules.rule.stop_processing")}/
  end

  test "reorder saves the new run order" do
    family = @user.family
    family.rules.destroy_all
    a = family.rules.create!(name: "A", resource_type: "transaction", actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    b = family.rules.create!(name: "B", resource_type: "transaction", actions: [ Rule::Action.new(action_type: "exclude_transaction") ])

    patch reorder_rules_url, params: { rule_ids: [ b.id, a.id ] }, as: :json

    assert_response :no_content
    assert_equal [ b, a ], family.rules.ordered.to_a
  end

  test "reorder refuses a list that does not name every rule once" do
    family = @user.family
    family.rules.destroy_all
    a = family.rules.create!(name: "A", resource_type: "transaction", actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    family.rules.create!(name: "B", resource_type: "transaction", actions: [ Rule::Action.new(action_type: "exclude_transaction") ])

    patch reorder_rules_url, params: { rule_ids: [ a.id ] }, as: :json

    assert_response :unprocessable_entity
  end

  test "reorder cannot move another family's rule" do
    other_rule = families(:empty).rules.create!(resource_type: "transaction", actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    own_ids = @user.family.rules.pluck(:id)

    patch reorder_rules_url, params: { rule_ids: own_ids + [ other_rule.id ] }, as: :json

    assert_response :unprocessable_entity
  end

  test "update saves stop processing" do
    rule = rules(:one)

    patch rule_url(rule), params: { rule: { stop_processing: "1" } }

    assert rule.reload.stop_processing?
  end

  test "apply enqueues the rule after the active rules above it" do
    rule = rules(:one)

    assert_enqueued_with(job: ApplyRulesJob, args: [ rule.family, { rule_ids: [ rule.id ], ignore_attribute_locks: true, execution_type: "manual" } ]) do
      post apply_rule_url(rule)
    end

    assert rule.reload.active?
  end

  test "confirm says how many active rules above run first" do
    family = @user.family
    family.rules.destroy_all
    family.rules.create!(name: "Above", resource_type: "transaction", active: true, actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    rule = family.rules.create!(name: "Below", resource_type: "transaction", actions: [ Rule::Action.new(action_type: "exclude_transaction") ])

    get confirm_rule_url(rule)

    assert_response :success
    assert_includes response.body, I18n.t("rules.confirm.rules_above_notice", count: 1)
  end

  test "recent runs show the blocked count" do
    rule = rules(:one)
    RuleRun.create!(rule: rule, rule_name: "Blocked", execution_type: "manual", status: "success",
                    transactions_queued: 5, transactions_processed: 5, transactions_modified: 2, pending_jobs_count: 0, executed_at: Time.current)

    get rules_url

    assert_response :success
    assert_includes response.body, I18n.t("rules.recent_runs.columns.transactions_counts.blocked")
    assert_includes response.body, "5 / 5 / 2 / 3"
  end

  test "creates a rule with the new text operators" do
    assert_difference -> { @user.family.rules.count }, 1 do
      post rules_url, params: {
        rule: {
          resource_type: "transaction",
          conditions_attributes: {
            "0" => { condition_type: "transaction_name", operator: "starts_with", value: "AMZN" },
            "1" => { condition_type: "transaction_notes", operator: "is_not_null", value: "" },
            "2" => { condition_type: "transaction_name", operator: "matches_regex", value: "^amzn\\s+mktp" }
          },
          actions_attributes: { "0" => { action_type: "exclude_transaction" } }
        }
      }
    end

    rule = @user.family.rules.order(:created_at).last
    assert_equal %w[is_not_null matches_regex starts_with], rule.conditions.map(&:operator).sort
  end

  test "an invalid regex shows the form again with the error" do
    assert_no_difference -> { @user.family.rules.count } do
      post rules_url, params: {
        rule: {
          resource_type: "transaction",
          conditions_attributes: { "0" => { condition_type: "transaction_name", operator: "matches_regex", value: "(" } },
          actions_attributes: { "0" => { action_type: "exclude_transaction" } }
        }
      }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("activerecord.errors.models.rule/condition.attributes.value.regex_invalid")
  end

  test "an unknown condition type, operator or action type gets a plain 422" do
    [
      { conditions_attributes: { "0" => { condition_type: "bogus", operator: "=", value: "x" } }, actions_attributes: { "0" => { action_type: "exclude_transaction" } } },
      { conditions_attributes: { "0" => { condition_type: "transaction_name", operator: "bogus", value: "x" } }, actions_attributes: { "0" => { action_type: "exclude_transaction" } } },
      { actions_attributes: { "0" => { action_type: "send_email_notification", value: "x" } } }
    ].each do |attributes|
      assert_no_difference -> { @user.family.rules.count } do
        post rules_url, params: { rule: { resource_type: "transaction" }.merge(attributes) }
      end

      assert_response :unprocessable_entity
      assert_equal "text/plain", response.media_type
    end
  end

  test "new ignores an unknown resource type or action type prefill" do
    get new_rule_url(resource_type: "account", action_type: "send_email_notification", action_value: "x")

    assert_response :success
  end

  test "index renders a rule with an unsupported condition type" do
    rule = @user.family.rules.create!(
      resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "coffee") ],
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )
    rule.conditions.first.update_columns(condition_type: "name_removed")

    get rules_url

    assert_response :success
    assert_includes response.body, "Unsupported (name_removed)"
  end
end
