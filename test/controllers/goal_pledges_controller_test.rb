require "test_helper"

# goal-pledges. Ported from upstream without the preview gate.
class GoalPledgesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    @goal = goals(:vacation_italy)
    @account = accounts(:depository)
    @pledge = goal_pledges(:open_transfer)
  end

  test "new renders the pledge form inside a turbo frame" do
    get new_goal_pledge_url(@goal), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "form[action=?]", goal_pledges_path(@goal)
    assert_select "[data-controller='goal-pledge-preview']"
  end

  test "new labels a foreign-currency account with its currency" do
    eur = Account.create!(family: @user.family, accountable: Depository.new,
                          name: "Euro Savings", currency: "EUR", balance: 1_000)
    @goal.goal_accounts.create!(account: eur, allocated_amount: 500)

    get new_goal_pledge_url(@goal), headers: { "Turbo-Frame" => "modal" }

    assert_select "option", text: "Euro Savings · EUR"
    assert_select "option", text: @account.name
  end

  test "new prefills the amount it is given" do
    get new_goal_pledge_url(@goal, amount: 125), headers: { "Turbo-Frame" => "modal" }

    assert_select "input[name='goal_pledge[amount]'][value^='125']"
  end

  test "new goes back to the goal page on a direct GET" do
    get new_goal_pledge_url(@goal)

    assert_redirected_to goal_path(@goal)
  end

  test "create opens a pledge with the account's kind and the goal's currency" do
    assert_difference -> { GoalPledge.count } => 1 do
      post goal_pledges_url(@goal), params: { goal_pledge: { amount: "150", account_id: @account.id } }
    end

    pledge = GoalPledge.order(created_at: :desc).first
    assert pledge.open?
    assert_equal @goal.id, pledge.goal_id
    assert_equal "manual_save", pledge.kind
    assert_equal @goal.currency, pledge.currency
    assert_redirected_to goal_path(@goal)
    assert_equal I18n.t("goal_pledges.create.success"), flash[:notice]
  end

  test "create refuses an account the goal is not funded by" do
    assert_no_difference -> { GoalPledge.count } do
      post goal_pledges_url(@goal), params: { goal_pledge: { amount: "150", account_id: accounts(:investment).id } }
    end

    assert_response :unprocessable_entity
  end

  test "create refuses an amount of zero" do
    assert_no_difference -> { GoalPledge.count } do
      post goal_pledges_url(@goal), params: { goal_pledge: { amount: "0", account_id: @account.id } }
    end

    assert_response :unprocessable_entity
  end

  test "renew pushes the expiry forward" do
    before = @pledge.expires_at

    patch renew_goal_pledge_url(@goal, @pledge)

    assert_redirected_to goal_path(@goal)
    assert @pledge.reload.expires_at > before
  end

  test "renew on a pledge that is not open says so" do
    patch renew_goal_pledge_url(@goal, goal_pledges(:matched_transfer))

    assert_redirected_to goal_path(@goal)
    assert_equal I18n.t("goal_pledges.renew.not_open"), flash[:alert]
  end

  test "destroy cancels an open pledge and keeps the row" do
    assert_no_difference -> { GoalPledge.count } do
      delete goal_pledge_url(@goal, @pledge)
    end

    assert_redirected_to goal_path(@goal)
    assert @pledge.reload.cancelled?
  end

  test "destroy on a pledge that is not open says so" do
    pledge = goal_pledges(:matched_transfer)

    delete goal_pledge_url(@goal, pledge)

    assert_redirected_to goal_path(@goal)
    assert_equal I18n.t("goal_pledges.destroy.not_open"), flash[:alert]
    assert pledge.reload.matched?
  end

  test "the goal page shows the pending pledge with its actions" do
    get goal_url(@goal)

    assert_response :success
    assert_select "form[action=?]", renew_goal_pledge_path(@goal, @pledge)
    assert_select "form[action=?]", goal_pledge_path(@goal, @pledge)
  end

  # vacation_italy is past its target, so it asks for no more pledges; a goal still
  # short of it offers the button
  test "a goal still being funded offers recording a pledge" do
    account = Account.create!(family: @user.family, accountable: Depository.new,
                              name: "Short Pot #{SecureRandom.hex(3)}", currency: "USD", balance: 100)
    goal = @user.family.goals.create!(name: "Short", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end

    get goal_url(goal)
    assert_select "a[href^=?]", new_goal_pledge_path(goal)

    get goal_url(@goal)
    assert_select "a[href^=?]", new_goal_pledge_path(@goal), count: 0
  end

  test "the goals index says some pledges are pending" do
    get goals_url

    assert_response :success
    assert_match I18n.t("goals.index.pending_pledges_callout"), response.body
  end

  test "another family's goal redirects with not found" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    other_account = Account.create!(family: other_family, accountable: Depository.new, name: "Foreign", currency: "USD", balance: 100)
    other_goal = other_family.goals.new(name: "Foreign goal", target_amount: 100, currency: "USD")
    other_goal.goal_accounts.build(account: other_account)
    other_goal.save!

    get new_goal_pledge_url(other_goal), headers: { "Turbo-Frame" => "modal" }

    assert_redirected_to goals_path
    assert_equal I18n.t("goals.errors.not_found"), flash[:alert]
  end
end
