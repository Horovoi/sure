require "test_helper"

# Ported from upstream (savings-goals, goal-spending) without the preview gate, the
# Plan hub and account sharing. Linkable accounts are the family's active manual
# accounts of a fundable type.
class GoalsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    sign_in @user
    @goal = goals(:vacation_italy)
    @depository = accounts(:depository)
    @connected = accounts(:connected)
  end

  test "index renders without a preview gate" do
    get goals_url
    assert_response :success
    assert_match(/Goals/i, response.body)
  end

  test "the goals page sits under Plan in the nav and the breadcrumbs" do
    get goals_url
    assert_select "a[href=?][aria-current=page]", plan_path, minimum: 1
    assert_select "a[href=?]", plan_path, text: I18n.t("breadcrumbs.plan")
  end

  test "show renders the goal" do
    get goal_url(@goal)
    assert_response :success
    assert_match(@goal.name, response.body)
  end

  test "new renders the modal form" do
    get new_goal_url
    assert_response :success
  end

  test "the target amount field keeps its own action alongside the paste handler" do
    get new_goal_url

    assert_response :success
    assert_select "input[data-money-field-target=?][data-action=?]", "amount",
                  "input->goal-form#suggestedChanged paste->money-field#pasteAmount blur->money-field#normalizeAmount"
  end

  test "create persists a goal with linked accounts" do
    # Fresh accounts: the fixtures already claim @depository and @connected in full
    first = unclaimed_account("Holiday Pot")
    second = unclaimed_account("House Pot")

    assert_difference -> { Goal.count } => 1, -> { GoalAccount.count } => 2 do
      post goals_url, params: {
        goal: {
          name: "New goal",
          target_amount: "1000",
          target_date: 3.months.from_now.to_date.iso8601,
          color: "#4da568",
          account_ids: [ first.id, second.id ]
        }
      }
    end

    goal = Goal.order(created_at: :desc).first
    assert_redirected_to goal_path(goal)
    assert_equal @user.family.primary_currency_code, goal.currency
  end

  test "a goal created from the Plan page goes back to the Plan page" do
    account = unclaimed_account("Plan Pot")

    get new_goal_url(return_to: plan_path)
    assert_select "form input[type=hidden][name=return_to][value=?]", plan_path

    post goals_url, params: {
      return_to: plan_path,
      goal: { name: "From plan", target_amount: "500", color: "#4da568", account_ids: [ account.id ] }
    }

    assert_redirected_to plan_path
  end

  test "create ignores a return_to that leaves the app" do
    account = unclaimed_account("Outside Pot")

    post goals_url, params: {
      return_to: "https://evil.example/",
      goal: { name: "Elsewhere", target_amount: "500", color: "#4da568", account_ids: [ account.id ] }
    }

    assert_redirected_to goal_path(Goal.order(created_at: :desc).first)
  end

  test "a rejected creation keeps the page to go back to" do
    post goals_url, params: { return_to: plan_path, goal: { name: "", target_amount: "500" } }

    assert_response :unprocessable_entity
    assert_select "form input[type=hidden][name=return_to][value=?]", plan_path
  end

  test "create rejects missing account_ids" do
    assert_no_difference "Goal.count" do
      post goals_url, params: { goal: { name: "Bad goal", target_amount: "1000", color: "#4da568" } }
    end
    assert_response :unprocessable_entity
  end

  test "create rejects foreign accounts" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    foreign = Account.create!(family: other_family, accountable: Depository.new, name: "Foreign", currency: "USD", balance: 100)

    assert_no_difference "Goal.count" do
      post goals_url, params: { goal: { name: "Foreign goal", target_amount: "1000", color: "#4da568", account_ids: [ foreign.id ] } }
    end
    assert_response :unprocessable_entity
  end

  # Bank providers stay hidden in this app, so a provider-linked account is not offered
  test "the funding picker lists only active manual accounts of a fundable type" do
    disabled = unclaimed_account("Disabled Pot")
    disabled.update_column(:status, "disabled")

    get new_goal_url

    assert_response :success
    assert_select "input[name='goal[account_ids][]'][value=?]", @depository.id
    assert_select "input[name='goal[account_ids][]'][value=?]", @connected.id, count: 0
    assert_select "input[name='goal[account_ids][]'][value=?]", disabled.id, count: 0
    assert_select "input[name='goal[account_ids][]'][value=?]", accounts(:credit_card).id, count: 0
  end

  test "create refuses a provider-linked account" do
    assert_no_difference "Goal.count" do
      post goals_url, params: { goal: { name: "Linked", target_amount: "1000", account_ids: [ @connected.id ] } }
    end
    assert_response :unprocessable_entity
  end

  test "update modifies identity fields" do
    patch goal_url(@goal), params: { goal: { name: "Renamed" } }
    assert_redirected_to goal_path(@goal)
    assert_equal "Renamed", @goal.reload.name
  end

  test "update without account_ids leaves linked accounts intact" do
    before = @goal.goal_accounts.pluck(:account_id).sort
    patch goal_url(@goal), params: { goal: { name: "Still here" } }
    assert_redirected_to goal_path(@goal)
    assert_equal before, @goal.reload.goal_accounts.pluck(:account_id).sort
  end

  test "update with account_ids syncs linked accounts (add + remove)" do
    pot = unclaimed_account("Swap Pot")

    patch goal_url(@goal), params: { goal: { name: @goal.name, account_ids: [ pot.id ] } }

    assert_redirected_to goal_path(@goal)
    linked = @goal.reload.goal_accounts.pluck(:account_id)
    assert_includes linked, pot.id
    assert_not_includes linked, @depository.id
  end

  # The picker never shows a provider-linked account, so its absence from the form is
  # not a removal
  test "update keeps a link to an account the picker does not show" do
    patch goal_url(@goal), params: { goal: { name: @goal.name, account_ids: [ @depository.id ] } }

    assert_redirected_to goal_path(@goal)
    assert_equal [ @connected.id, @depository.id ].sort, @goal.reload.goal_accounts.pluck(:account_id).sort
  end

  test "update with empty account_ids re-renders with error" do
    patch goal_url(@goal), params: { goal: { name: @goal.name, account_ids: [ "" ] } }
    assert_response :unprocessable_entity
    assert_not_empty @goal.reload.goal_accounts
  end

  test "update changes the earmark of a kept link" do
    patch goal_url(@goal), params: {
      goal: { name: @goal.name, account_ids: [ @depository.id ], allocations: { @depository.id.to_s => "750" } }
    }

    assert_redirected_to goal_path(@goal)
    assert_equal 750, @goal.goal_accounts.find_by!(account: @depository).allocated_amount
  end

  test "update accepts a foreign-currency account and converts its backing" do
    eur_account = Account.create!(family: @goal.family, accountable: Depository.new, name: "EUR Checking", currency: "EUR", balance: 100)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.2)

    patch goal_url(@goal), params: { goal: { name: @goal.name, account_ids: [ eur_account.id ] } }

    assert_redirected_to goal_path(@goal)
    assert_includes @goal.reload.goal_accounts.pluck(:account_id), eur_account.id
    assert_equal "USD", @goal.currency
  end

  test "show and index disclose an unavailable account conversion" do
    eur = Account.create!(family: @user.family, accountable: Depository.new, name: "EUR reserve", currency: "EUR", balance: 100)
    @goal.goal_accounts.build(account: eur)
    @goal.save!
    ExchangeRate.stubs(:provider).returns(nil)

    warning = I18n.t("goals.currency_warning.body", count: 1, from: "EUR", to: @goal.currency)

    get goal_url(@goal)
    assert_response :success
    assert_select "p", text: I18n.t("goals.show.funding_accounts.rate_unavailable")
    assert_includes response.body, warning
    # Above the headline figures, not below the funding breakdown
    assert_operator response.body.index(warning), :<, response.body.index(I18n.t("goals.show.funding_accounts_heading"))

    get goals_url
    assert_response :success
    assert_select "p", text: I18n.t("goals.goal_card.partial_total")
  end

  test "pause/resume/complete/archive/unarchive/reopen flow" do
    fresh = goals(:emergency_fund)
    patch pause_goal_url(fresh)
    assert fresh.reload.paused?
    patch resume_goal_url(fresh)
    assert fresh.reload.active?
    patch complete_goal_url(fresh)
    assert fresh.reload.completed?
    patch reopen_goal_url(fresh)
    assert fresh.reload.active?
    patch archive_goal_url(fresh)
    assert fresh.reload.archived?
    patch unarchive_goal_url(fresh)
    assert fresh.reload.active?
  end

  test "show exposes delete for a goal in every state" do
    delete_form = "form[action='#{goal_path(@goal)}'] input[name='_method'][value='delete']"

    %w[active paused completed archived].each do |state|
      @goal.update_column(:state, state)

      get goal_url(@goal)

      assert_response :success
      assert_select delete_form, 1, "no delete affordance on a #{state} goal"
    end
  end

  # A goal whose last funding account is deleted survives with zero links; editing is
  # the way back, so update validates the submitted accounts
  test "an orphaned goal can be repaired by re-linking an account" do
    orphan = orphaned_goal
    rescue_account = unclaimed_account("Rescue Pot")

    patch goal_url(orphan), params: { goal: { name: orphan.name, target_amount: orphan.target_amount, account_ids: [ rescue_account.id ] } }

    assert_redirected_to goal_path(orphan)
    assert_equal [ rescue_account.id ], orphan.reload.goal_accounts.pluck(:account_id)
    assert orphan.valid?
  end

  test "a transition that fails validation reports the error, not success" do
    orphan = orphaned_goal

    patch archive_goal_url(orphan)

    assert_redirected_to goal_path(orphan)
    assert_nil flash[:notice]
    assert_match(/at least one account/i, flash[:alert])
    assert_equal "active", orphan.reload.state
  end

  test "destroy deletes a goal and its links, and leaves the accounts" do
    assert_difference -> { Goal.count } => -1, -> { GoalAccount.count } => -2, -> { Account.count } => 0 do
      delete goal_url(@goal)
    end
    assert_redirected_to goals_path
  end

  test "destroy deletes an archived goal" do
    @goal.archive!
    assert_difference "Goal.count", -1 do
      delete goal_url(@goal)
    end
    assert_redirected_to goals_path
  end

  test "index KPI swaps to 'All caught up' when every tracked goal is reached" do
    family = @user.family
    family.goals.destroy_all
    build_goal(family, "Wedding", target_amount: 1, target_date: 1.year.from_now)

    get goals_url
    assert_response :success
    assert_match(/All caught up/i, response.body)
    assert_match(/1\s*reached/i, response.body)
  end

  test "index KPI gives a percent change only between two contributions" do
    Goal.stubs(:inflow_windows_for).returns({ current: 150.to_d, prior: 100.to_d })
    get goals_url
    assert_match I18n.t("goals.index.kpi.velocity_delta_up", percent: 50.0), response.body

    # From contributions to net withdrawals: no "↓ 504.7%"
    Goal.stubs(:inflow_windows_for).returns({ current: -404.7.to_d, prior: 100.to_d })
    get goals_url
    assert_match I18n.t("goals.index.kpi.velocity_delta_down_no_percent"), response.body
    assert_no_match(/504\.7%/, response.body)

    Goal.stubs(:inflow_windows_for).returns({ current: 80.to_d, prior: 0.to_d })
    get goals_url
    assert_match I18n.t("goals.index.kpi.velocity_delta_zero_base"), response.body
  end

  test "index KPI 'on track' denominator excludes no-target-date goals" do
    family = @user.family
    family.goals.destroy_all
    build_goal(family, "House", target_amount: 1_000_000, target_date: 1.year.from_now)
    build_goal(family, "Emergency", target_amount: 1_000_000, target_date: nil)

    get goals_url
    assert_response :success
    assert_match(/0\s*of\s*1/i, response.body)
    assert_match(/without a deadline/i, response.body)
  end

  test "a rejected creation keeps the accounts the user ticked" do
    account = unclaimed_account("Contested Pot")
    @user.family.goals.create!(name: "Holder", target_amount: 5_000, currency: "USD") { |g| g.goal_accounts.build(account: account) }

    post goals_url, params: {
      goal: { name: "Second claim", target_amount: 5_000, account_ids: [ account.id ], allocations: { account.id.to_s => "" } }
    }

    assert_response :unprocessable_entity
    assert_select "input[type=checkbox][name='goal[account_ids][]'][value=?][checked]", account.id
  end

  test "a one_off goal at 100 percent is offered closing, not archiving" do
    goal = fully_funded_goal

    get goal_url(goal)

    assert_response :success
    assert_match I18n.t("goals.show.celebration.close_cta"), response.body
    assert_no_match(/#{Regexp.escape(I18n.t("goals.show.celebration.archive_cta"))}/, response.body)
  end

  test "a goal below 100 percent is offered no closing action" do
    goal = fully_funded_goal
    goal.update!(target_amount: 10_000)

    get goal_url(goal)

    assert_response :success
    assert_no_match(/#{Regexp.escape(I18n.t("goals.show.celebration.close_cta"))}/, response.body)
  end

  test "a completed goal shows the amount and date it froze" do
    goal = fully_funded_goal
    goal.complete!

    get goal_url(goal)

    assert_response :success
    assert_match I18n.t("goals.show.celebration.frozen",
                        date: I18n.l(goal.reload.completed_at.to_date, format: :long),
                        amount: goal.current_balance_money.format(precision: 0)),
                 response.body
  end

  test "create accepts the maintained kind" do
    account = unclaimed_account("Reserve Pot")

    assert_difference -> { Goal.count }, 1 do
      post goals_url, params: { goal: { name: "Emergency", target_amount: "6000", color: "#4da568", kind: "maintained", account_ids: [ account.id ] } }
    end

    assert Goal.order(created_at: :desc).first.maintained?
  end

  test "completing a reserve is refused at the controller too" do
    goal = fully_funded_goal
    goal.update_column(:kind, "maintained")

    patch complete_goal_url(goal)

    assert_redirected_to goal_path(goal)
    assert_match(/./, flash[:alert].to_s)
    assert_equal "active", goal.reload.state
  end

  test "a funded reserve reads as intact, with nothing to do" do
    goal = fully_funded_goal
    goal.update_column(:kind, "maintained")

    get goal_url(goal)

    assert_response :success
    assert_match I18n.t("goals.show.celebration.heading_reserve"), response.body
    assert_no_match(/#{Regexp.escape(I18n.t("goals.show.celebration.close_cta"))}/, response.body)
  end

  test "a reserve stays out of the on-track denominator" do
    @user.family.goals.where.not(state: "archived").find_each(&:archive!)
    @user.family.goals.create!(name: "Precaution", target_amount: 6_000, currency: "USD", kind: "maintained") do |g|
      g.goal_accounts.build(account: unclaimed_account("Reserve Pot"))
    end

    get goals_url

    assert_response :success
    assert_no_match(/0 of 1/, response.body)
    assert_match(/0 of 0/, response.body)
  end

  test "a reserve with nothing in it yet gets the shortfall panel" do
    account = unclaimed_account("Empty Reserve Pot")
    account.update!(balance: 0)
    goal = @user.family.goals.create!(name: "Precaution", target_amount: 6_000, currency: "USD", kind: "maintained") do |g|
      g.goal_accounts.build(account: account)
    end

    get goal_url(goal)

    assert_response :success
    assert_match I18n.t("goals.show.reserve_shortfall.heading"), response.body
  end

  test "the new form renders each account's balance and what other goals hold" do
    account = unclaimed_account("Headroom Pot")
    @user.family.goals.create!(name: "Neighbour", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 400)
    end

    get new_goal_url

    assert_response :success
    assert_match 'data-earmarked-by-others="400.0"', response.body
  end

  test "the form reads the shared pool exactly once, however many accounts" do
    3.times { |i| unclaimed_account("Pool Pot #{i}") }

    assert_equal 1, count_pool_queries { get new_goal_url }
    assert_response :success
  end

  test "the edit form does not count the edited goal's own earmark" do
    account = unclaimed_account("Reopen Pot")
    goal = @user.family.goals.create!(name: "Reopened", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 5_000)
    end

    get edit_goal_url(goal)

    assert_response :success
    assert_no_match(/data-earmarked-by-others="5000/, response.body)
  end

  test "the pool is available again when create re-renders after an error" do
    unclaimed_account("Error Pot")

    post goals_url, params: { goal: { name: "No accounts", target_amount: "1000", color: "#4da568" } }

    assert_response :unprocessable_entity
    assert_select "[data-balance][data-earmarked-by-others]", minimum: 1
  end

  test "a months-of-expenses reserve can be created without typing an amount" do
    account = unclaimed_account("Reserve Pot")
    IncomeStatement.any_instance.stubs(:median_expense).returns(500)

    assert_difference -> { Goal.count }, 1 do
      post goals_url, params: { goal: {
        name: "Precaution", color: "#4da568", kind: "maintained",
        target_mode: "months_of_expenses", target_months: "6",
        target_amount: "", account_ids: [ account.id ]
      } }
    end

    goal = Goal.order(created_at: :desc).first
    assert_equal 3_000, goal.target_amount.to_d
    assert goal.maintained?
  end

  test "a fixed-amount goal still requires the amount" do
    account = unclaimed_account("Fixed Pot")

    assert_no_difference -> { Goal.count } do
      post goals_url, params: { goal: { name: "No amount", color: "#4da568", target_amount: "", account_ids: [ account.id ] } }
    end

    assert_response :unprocessable_entity
    assert_select "[data-goal-form-target=amountError]:not(.hidden)", 1
  end

  test "the goal page reports the used portion as part of the total" do
    goal = spent_goal_for_display

    get goal_url(goal)

    assert_response :success
    assert_includes response.body, I18n.t("goals.show.ring.including_used", amount: goal.consumed_amount_money.format(precision: 0))
    label = css_select("[role=progressbar]").first["aria-label"]
    assert_includes label, goal.progress_amount_money.format
  end

  test "the form carries the derived balance as a result, not a field" do
    unclaimed_account("Derived Pot")

    get new_goal_url

    assert_response :success
    assert_select "[data-goal-kind-target=amountDerived]", 1
    assert_includes response.body, I18n.t("goals.form.fields.target_balance_pending")
  end

  test "each account's earmark is a money field that stays editable in privacy mode" do
    account = unclaimed_account("Earmark Pot")

    get new_goal_url

    assert_response :success
    assert_select "input#goal_allocations_#{account.id}[name='goal[allocations][#{account.id}]']", count: 1 do |inputs|
      input = inputs.first
      # Inputs keep their pointer events in privacy mode (see privacy-mode.css)
      assert_includes input["class"].split, "privacy-sensitive"
      assert_equal "allocationInput", input["data-goal-earmark-target"]
    end
  end

  test "a fixed earmark is filled back into its account's field" do
    account = unclaimed_account("Filled Pot")
    goal = @user.family.goals.create!(name: "Filled", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 250)
    end

    get edit_goal_url(goal)

    assert_response :success
    assert_select "input#goal_allocations_#{account.id}[value='250.00']"
  end

  test "the icon picker drives the goal's own color and icon controller" do
    get new_goal_url

    assert_response :success
    assert_select "[data-controller='color-icon-picker']", 1
    assert_select "input[name='goal[icon]'][data-color-icon-picker-target='icon']", minimum: 1
  end

  test "create ignores forbidden params (family_id, state)" do
    family = @user.family
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")

    assert_difference -> { family.goals.count }, 1 do
      post goals_url, params: {
        goal: {
          name: "Hijack target", target_amount: 100, currency: "USD", state: "archived",
          family_id: other_family.id, account_ids: [ unclaimed_account("Hijack Pot").id ]
        }
      }
    end

    goal = family.goals.order(:created_at).last
    assert_equal "active", goal.state
    assert_equal family.id, goal.family_id
  end

  test "another family's goal redirects with not found" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    other_account = Account.create!(family: other_family, accountable: Depository.new, name: "Foreign", currency: "USD", balance: 100)
    other_goal = other_family.goals.new(name: "Foreign goal", target_amount: 100, currency: "USD")
    other_goal.goal_accounts.build(account: other_account)
    other_goal.save!

    get goal_url(other_goal)
    assert_redirected_to goals_path
    assert_equal I18n.t("goals.errors.not_found"), flash[:alert]
  end

  # --- Spending from a goal (goal-spending) ---

  test "the consumption dialog asks for the amount with a labelled money field" do
    get consume_goal_url(@goal)

    assert_response :success
    assert_select "[data-controller='money-field'] input[type=text][name=amount][id=amount][autofocus]"
    assert_select "label[for=amount]", text: /#{I18n.t("goals.consume.amount_label")}/
  end

  test "the consumption dialog names a foreign account's currency" do
    ExchangeRate.stubs(:provider).returns(nil)
    eur = Account.create!(family: @user.family, accountable: Depository.new,
                          name: "Euro Savings", currency: "EUR", balance: 1_000)
    @goal.goal_accounts.create!(account: eur, allocated_amount: 500)

    get consume_goal_url(@goal)

    assert_response :success
    assert_includes response.body, "Euro Savings · EUR"
    assert_select "p", text: I18n.t("goals.consume.goal_currency_hint", currency: "USD")
  end

  test "the progress percent follows one privacy rule on the goal page and the goal cards" do
    get goal_url(@goal)
    assert_select "[data-testid=goal-ring-percent]:not(.privacy-sensitive)", text: /\d+%/

    get goals_url
    assert_select ".privacy-sensitive", text: /\A\s*\d+%\s*\z/, count: 0
  end

  test "the consumption dialog blurs its figures under privacy mode" do
    get consume_goal_url(@goal)

    assert_response :success
    assert_select "input[name=amount].form-field__input.privacy-sensitive"
    assert_select "p.privacy-sensitive", text: /is currently backing this goal/
  end

  test "recording a spend keeps the goal at full progress and frees the earmark" do
    goal = spend_goal

    post consume_goal_url(goal), params: { amount: 2_000 }

    assert_redirected_to goal_url(goal)
    assert_equal 2_000, goal.reload.consumed_amount
    assert_equal 3_000, goal.goal_accounts.first.reload.allocated_amount
    assert_equal 100, goal.progress_percent
  end

  test "a refused spend says which rule refused it" do
    account = unclaimed_account("Reserve Pot")
    reserve = @user.family.goals.create!(
      name: "Precaution", target_amount: 6_000, currency: "USD", kind: "maintained"
    ) { |g| g.goal_accounts.build(account: account) }

    post consume_goal_url(reserve), params: { amount: 500 }

    assert_redirected_to goal_url(reserve)
    assert_equal I18n.t("goals.consume.errors.maintained"), flash[:alert]
    assert_equal 0, reserve.reload.consumed_amount
  end

  # A blank account id means "the one link". An id that resolves to nothing must not
  # fall back to it.
  test "an unknown account id is refused rather than falling through" do
    goal = spend_goal

    post consume_goal_url(goal), params: { amount: 1_000, account_id: SecureRandom.uuid }

    assert_equal I18n.t("goals.consume.errors.account_not_linked"), flash[:alert]
    assert_equal 0, goal.reload.consumed_amount
  end

  test "a spend without an exchange rate is refused with the missing-rate message" do
    eur = Account.create!(family: @user.family, accountable: Depository.new,
                          name: "Euro Pot", currency: "EUR", balance: 1_000)
    goal = @user.family.goals.create!(name: "Euro trip", target_amount: 2_000, currency: "USD") do |g|
      g.goal_accounts.build(account: eur, allocated_amount: 800)
    end
    ExchangeRate.stubs(:find_rate).returns(nil)

    post consume_goal_url(goal), params: { amount: 100 }

    assert_redirected_to goal_url(goal)
    assert_equal I18n.t("goals.consume.errors.missing_exchange_rate"), flash[:alert]
    assert_equal 0, goal.reload.consumed_amount
  end

  test "the goal page offers an outflow nothing has claimed" do
    goal, entry = goal_with_outflow

    get goal_url(goal)

    assert_response :success
    assert_match I18n.t("goals.unattributed_outflows.heading"), response.body
    assert_match entry.name, response.body
  end

  test "attributing an outflow takes its amount and stops offering it" do
    goal, entry = goal_with_outflow

    post consume_goal_url(goal), params: { transaction_id: entry.entryable_id }

    assert_redirected_to goal_url(goal)
    assert_equal entry.amount.to_d, goal.reload.consumed_amount
    assert_equal goal.id, entry.entryable.reload.extra.dig("goal", "consumed_goal_id")

    get goal_url(goal)
    assert_no_match I18n.t("goals.unattributed_outflows.heading"), response.body
  end

  test "the same outflow cannot be attributed twice" do
    goal, entry = goal_with_outflow
    post consume_goal_url(goal), params: { transaction_id: entry.entryable_id }
    recorded = goal.reload.consumed_amount

    post consume_goal_url(goal), params: { transaction_id: entry.entryable_id }

    assert_equal recorded, goal.reload.consumed_amount
    assert_equal I18n.t("goals.consume.errors.transaction_not_found"), flash[:alert]
  end

  test "detected foreign spending is converted on its date and releases native units" do
    ExchangeRate.stubs(:provider).returns(nil)
    eur = Account.create!(family: @user.family, accountable: Depository.new,
                          name: "EUR spending", currency: "EUR", balance: 1_000)
    goal = @user.family.goals.create!(name: "Euro trip", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: eur, allocated_amount: 500)
    end
    date = 20.days.ago.to_date
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: date, rate: 2)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 3)
    entry = eur.entries.create!(name: "Travel", date: date, amount: 100, currency: "EUR", entryable: Transaction.new)

    post consume_goal_url(goal), params: { transaction_id: entry.entryable_id }

    assert_redirected_to goal_path(goal)
    assert_equal 200, goal.reload.consumed_amount
    assert_equal 400, goal.goal_accounts.find_by!(account: eur).allocated_amount
  end

  test "the goal menu offers the spend dialog only for a goal that can be spent" do
    goal = spend_goal

    get goal_url(goal)
    assert_select "a[href=?]", consume_goal_path(goal)

    goal.pause!
    get goal_url(goal)
    assert_select "a[href=?]", consume_goal_path(goal), count: 0
  end

  private
    # 5,000 saved, 2,000 of it since spent. goal-spending records this with
    # Goal#consume!; the column is here already.
    def spent_goal_for_display
      account = unclaimed_account("Spent Pot")
      account.update!(balance: 5_000)
      goal = @user.family.goals.create!(name: "Trip", target_amount: 5_000, currency: "USD") do |g|
        g.goal_accounts.build(account: account, allocated_amount: 5_000)
      end
      goal.update_columns(consumed_amount: 2_000)
      goal
    end

    # SQL the pooled-allocation read issues: goal_accounts joined to goals
    def count_pool_queries
      count = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql].to_s
        count += 1 if sql.include?("FROM \"goal_accounts\"") && sql.include?("INNER JOIN \"goals\"")
      end
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    # An active one_off goal exactly at its target, on an account no other goal claims
    def fully_funded_goal
      account = unclaimed_account("Funded Pot")
      account.update!(balance: 2_000)
      @user.family.goals.create!(name: "Funded", target_amount: 2_000, currency: "USD") do |g|
        g.goal_accounts.build(account: account)
      end
    end

    # A fundable manual account no goal fixture claims
    def unclaimed_account(name)
      Account.create!(family: @user.family, accountable: Depository.new, name: name, currency: "USD", balance: 1_000)
    end

    # The state an account deletion leaves behind: zero links, failing validation
    def orphaned_goal
      throwaway = unclaimed_account("Throwaway")
      goal = @user.family.goals.new(name: "Orphan", target_amount: 500, currency: "USD")
      goal.goal_accounts.build(account: throwaway)
      goal.save!

      throwaway.destroy!
      goal.reload
      assert_empty goal.goal_accounts, "fixture setup failed to orphan the goal"
      goal
    end

    def build_goal(family, name, target_amount: 1_000_000, target_date: nil)
      funding = Account.create!(family: family, accountable: Depository.new, name: "#{name} Funding", currency: "USD", balance: @depository.balance)
      family.goals.create!(name: name, target_amount: target_amount, target_date: target_date, currency: "USD") do |g|
        g.goal_accounts.build(account: funding)
      end
    end

    # A one-off goal at its target on an account no fixture claims
    def spend_goal
      account = Account.create!(family: @user.family, accountable: Depository.new,
                                name: "Trip Pot #{SecureRandom.hex(3)}", currency: "USD", balance: 5_000)
      @user.family.goals.create!(name: "Trip", target_amount: 5_000, currency: "USD") do |g|
        g.goal_accounts.build(account: account, allocated_amount: 5_000)
      end
    end

    def goal_with_outflow
      goal = spend_goal
      entry = goal.linked_accounts.first.entries.create!(
        name: "Flights", date: Date.current, amount: 1_200, currency: "USD", entryable: Transaction.new
      )
      [ goal, entry ]
    end
end
