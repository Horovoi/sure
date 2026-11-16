require "test_helper"

class MonobankAccount::JarGoalTest < ActiveSupport::TestCase
  include MonobankTestHelper

  setup do
    setup_monobank_family
    @jar = create_monobank_product(account_id: "jar", kind: "jar", title: "Відпустка", balance: 150_000, goal: 2_000_000)
    @account = @item.create_linked_account!(monobank_account: @jar)
  end

  test "a linked jar with a target becomes a goal funded by the whole jar account" do
    assert_difference -> { Goal.count } => 1, -> { GoalAccount.count } => 1, -> { MonobankJarGoalLink.count } => 1 do
      assert_equal :created, sync(@jar)
    end

    goal = @jar.reload.linked_goal
    assert_equal [ "Відпустка", BigDecimal("20000"), "UAH", "one_off", "fixed", "active" ],
                 [ goal.name, goal.target_amount, goal.currency, goal.kind, goal.target_mode, goal.state ]
    assert_equal @family, goal.family
    goal_account = goal.goal_accounts.sole
    assert_equal @account, goal_account.account
    assert goal_account.whole_account?
    link = @jar.jar_goal_link
    assert_equal [ @family, "jar", @account, BigDecimal("20000"), "Відпустка", nil ],
                 [ link.family, link.jar_id, link.funding_account, link.synced_target, link.synced_title, link.dismissed_at ]
  end

  test "syncing again makes nothing new" do
    sync(@jar)

    assert_no_difference [ "Goal.count", "GoalAccount.count", "MonobankJarGoalLink.count" ] do
      assert_equal :unchanged, sync(@jar)
      assert_equal :unchanged, sync(@jar)
    end
  end

  test "the processor keeps the goal, so a jar linked before gets it on its next sync" do
    assert_nil @jar.reload.linked_goal_id

    assert_difference -> { Goal.count } => 1 do
      MonobankAccount::Processor.new(@jar.reload).process
      MonobankAccount::Processor.new(@jar.reload).process
    end
    assert_equal "Відпустка", @jar.reload.linked_goal.name
  end

  test "a jar in another currency gets a goal in that currency" do
    usd_jar = create_monobank_product(account_id: "usd-jar", kind: "jar", currency: "USD", title: "Laptop", goal: 150_000)
    @item.create_linked_account!(monobank_account: usd_jar)

    sync(usd_jar)

    goal = usd_jar.reload.linked_goal
    assert_equal [ BigDecimal("1500"), "USD" ], [ goal.target_amount, goal.currency ]
  end

  test "no goal for a jar without a target until it gets one" do
    jar = create_monobank_product(account_id: "reserve", kind: "jar", title: "Подушка", goal: nil)
    @item.create_linked_account!(monobank_account: jar)

    assert_no_difference [ "Goal.count", "MonobankJarGoalLink.count" ] do
      assert_nil sync(jar)
    end
    refresh(jar, title: "Подушка", goal: 0)
    assert_nil sync(jar), "a zero target is no target"

    refresh(jar, title: "Подушка", goal: 5_000_000)
    assert_difference "Goal.count", 1 do
      assert_equal :created, sync(jar)
    end
    assert_equal BigDecimal("50000"), jar.reload.linked_goal.target_amount
  end

  test "no goal for a card or an unlinked jar" do
    card = create_monobank_product(account_id: "card", goal: 1_000_000)
    @item.create_linked_account!(monobank_account: card)
    unlinked = create_monobank_product(account_id: "unlinked", kind: "jar", title: "Ще одна", goal: 1_000_000)

    assert_no_difference [ "Goal.count", "MonobankJarGoalLink.count" ] do
      assert_nil sync(card)
      assert_nil sync(unlinked)
      MonobankAccount::Processor.new(card.reload).process
    end
  end

  test "the target follows a change in monobank and otherwise keeps the owner's edit" do
    sync(@jar)
    goal = @jar.reload.linked_goal

    goal.update!(target_amount: 30_000)
    assert_equal :unchanged, sync(@jar)
    assert_equal BigDecimal("30000"), goal.reload.target_amount, "the owner's target stays while the jar's does not move"

    refresh(@jar, title: "Відпустка", goal: 2_500_000)
    assert_equal :updated, sync(@jar)
    assert_equal BigDecimal("25000"), goal.reload.target_amount, "a new target in monobank wins"
    assert_equal BigDecimal("25000"), @jar.jar_goal_link.synced_target
  end

  test "a renamed jar renames the goal only while the goal keeps the synced title" do
    sync(@jar)
    goal = @jar.reload.linked_goal

    refresh(@jar, title: "Відпустка в Карпатах", goal: 2_000_000)
    assert_equal :updated, sync(@jar)
    assert_equal "Відпустка в Карпатах", goal.reload.name
    assert_equal BigDecimal("20000"), goal.target_amount

    goal.update!(name: "Carpathians 2027")
    refresh(@jar, title: "Карпати", goal: 2_000_000)
    assert_equal :unchanged, sync(@jar)
    assert_equal "Carpathians 2027", goal.reload.name, "the owner's name stays"
    assert_equal "Карпати", @jar.jar_goal_link.synced_title
  end

  test "a jar that loses its target or its link leaves the goal as it is" do
    sync(@jar)
    goal = @jar.reload.linked_goal

    refresh(@jar, title: "Відпустка", goal: nil)
    assert_no_difference "Goal.count" do
      assert_equal :unchanged, sync(@jar)
    end
    assert_equal [ "Відпустка", BigDecimal("20000"), "active" ], [ goal.reload.name, goal.target_amount, goal.state ]

    Account::ProviderLink.unlink!(@account.reload)
    @item.process_accounts
    assert Goal.exists?(goal.id), "unlinking keeps the goal"
    assert_equal goal, @jar.reload.linked_goal
    assert_equal [ @account ], goal.reload.linked_accounts.to_a
  end

  test "a goal the owner deleted is not made again" do
    sync(@jar)
    @jar.reload.linked_goal.destroy!
    link = @jar.jar_goal_link
    assert_nil link.goal_id, "deleting the goal clears the link"
    assert_not_nil link.dismissed_at, "and records that the owner did it"

    assert_no_difference "Goal.count" do
      assert_equal :dismissed, sync(@jar)
      refresh(@jar, title: "Відпустка", goal: 3_000_000)
      assert_equal :dismissed, sync(@jar)
    end
  end

  test "a goal deleted without callbacks is not made again either" do
    sync(@jar)
    goal = @jar.reload.linked_goal
    GoalAccount.where(goal_id: goal.id).delete_all
    Goal.where(id: goal.id).delete_all
    assert_nil @jar.jar_goal_link.goal_id, "the foreign key clears the link"

    assert_no_difference "Goal.count" do
      assert_equal :dismissed, sync(@jar)
    end
    assert_not_nil @jar.jar_goal_link.dismissed_at
  end

  test "a jar whose account already funds another goal is skipped and logged" do
    other = @family.goals.new(name: "Own vacation goal", target_amount: 10_000, currency: "UAH")
    other.goal_accounts.build(account: @account, allocated_amount: 500)
    other.save!

    assert_no_difference "Goal.count" do
      assert_difference -> { jar_goal_logs.count } => 1 do
        assert_equal :skipped, sync(@jar)
      end
    end
    entry = jar_goal_logs.last
    assert_equal [ "info", @account.id, "Own vacation goal" ], [ entry.level, entry.account_id, entry.metadata["other_goal_name"] ]
    assert_nil @jar.reload.linked_goal_id

    # Once the other goal lets go of the account, the jar gets its own
    other.archive!
    assert_equal :created, sync(@jar)
  end

  test "a jar linked as an account type that cannot fund a goal is skipped" do
    jar = create_monobank_product(account_id: "jar-as-card", kind: "jar", title: "Борг", goal: 1_000_000)
    @item.create_linked_account!(monobank_account: jar, accountable_type: "CreditCard")

    assert_no_difference "Goal.count" do
      assert_equal :skipped, sync(jar)
    end
  end

  # Review finding: the goal kept the old account after a relink
  test "a jar linked to another Sure account moves its goal there and keeps the owner's other links" do
    sync(@jar)
    goal = @jar.reload.linked_goal
    savings = create_sure_account(name: "Savings")
    goal.goal_accounts.create!(account: savings, allocated_amount: 1_000)

    Account::ProviderLink.unlink!(@account.reload)
    jar_two = create_sure_account(name: "Mono jar 2")
    @item.link_existing_account!(monobank_account: @jar.reload, account: jar_two)

    assert_no_difference "Goal.count" do
      MonobankAccount::Processor.new(@jar.reload).process
    end
    links = goal.reload.goal_accounts.map { |link| [ link.account.name, link.allocated_amount ] }.sort_by(&:first)
    assert_equal [ [ "Mono jar 2", nil ], [ "Savings", BigDecimal("1000") ] ], links,
                 "the old jar account's link moved to the new one, the owner's earmark stayed"
    assert_equal jar_two, @jar.jar_goal_link.funding_account
    assert_equal :unchanged, sync(@jar)
  end

  # Review finding: after the account was deleted the goal had no account and every sync errored
  test "a jar whose account was deleted and linked again funds its goal from the new account" do
    sync(@jar)
    goal = @jar.reload.linked_goal
    @account.reload.destroy!
    assert_empty goal.reload.goal_accounts

    new_account = @item.create_linked_account!(monobank_account: @jar.reload)
    refresh(@jar, title: "Відпустка 2", goal: 2_500_000)

    with_cache do
      assert_no_difference -> { jar_goal_logs.where(level: "error").count } do
        assert_equal :updated, sync(@jar)
        assert_equal :unchanged, sync(@jar)
      end
    end
    goal.reload
    assert_equal [ "Відпустка 2", BigDecimal("25000") ], [ goal.name, goal.target_amount ]
    assert_equal [ [ new_account.id, nil ] ], goal.goal_accounts.map { |link| [ link.account_id, link.allocated_amount ] }
  end

  test "taking the jar account off its goal in Sure is the owner's edit and stays" do
    sync(@jar)
    goal = @jar.reload.linked_goal
    savings = create_sure_account(name: "Savings")
    goal.goal_accounts.create!(account: savings)
    goal.goal_accounts.find_by!(account: @account).destroy!

    refresh(@jar, title: "Відпустка", goal: 2_500_000)
    assert_equal :updated, sync(@jar)
    assert_equal [ savings ], goal.reload.linked_accounts.to_a
    assert_equal BigDecimal("25000"), goal.target_amount
  end

  test "a relink to an account that funds another goal is skipped and logged once a day" do
    sync(@jar)
    goal = @jar.reload.linked_goal
    taken = create_sure_account(name: "Taken")
    other = @family.goals.new(name: "House", target_amount: 10_000, currency: "UAH")
    other.goal_accounts.build(account: taken)
    other.save!
    Account::ProviderLink.unlink!(@account.reload)
    @item.link_existing_account!(monobank_account: @jar.reload, account: taken)
    refresh(@jar, title: "Renamed", goal: 2_500_000)

    with_cache do
      assert_difference -> { jar_goal_logs.count } => 1 do
        3.times { assert_equal :skipped, sync(@jar) }
      end
    end
    assert_equal [ "Відпустка", BigDecimal("20000"), [ @account ] ], [ goal.reload.name, goal.target_amount, goal.linked_accounts.to_a ]
    assert_equal "House", jar_goal_logs.last.metadata["other_goal_name"]
  end

  # Review finding: the link memory lived on monobank_accounts and was lost with the connection
  test "a jar connected again finds its goal, and a goal the owner deleted stays deleted" do
    sync(@jar)
    goal = @jar.reload.linked_goal
    car = create_monobank_product(account_id: "car", kind: "jar", title: "Car", goal: 1_000_000)
    car_account = @item.create_linked_account!(monobank_account: car)
    sync(car)
    car.reload.linked_goal.destroy!

    @item.reload.destroy!
    assert Account.exists?(@account.id), "disconnecting keeps the Sure accounts"

    item = @family.monobank_items.create!(name: "monobank", access_token: "new_token")
    new_jar = create_monobank_product(account_id: "jar", kind: "jar", title: "Vacation renamed", goal: 3_000_000, item: item)
    new_car = create_monobank_product(account_id: "car", kind: "jar", title: "Car", goal: 1_000_000, item: item)
    item.link_existing_account!(monobank_account: new_jar, account: @account.reload)
    item.link_existing_account!(monobank_account: new_car, account: car_account.reload)

    assert_no_difference [ "Goal.count", "MonobankJarGoalLink.count" ] do
      assert_equal :updated, sync(new_jar)
      assert_equal :dismissed, sync(new_car)
    end
    assert_equal goal, new_jar.reload.linked_goal
    assert_equal [ "Vacation renamed", BigDecimal("30000"), [ @account ] ],
                 [ goal.reload.name, goal.target_amount, goal.linked_accounts.to_a ]
  end

  # Review finding: a closed goal got the target of the jar's next round
  test "a completed or archived goal keeps its target and name, and reopening replays nothing" do
    sync(@jar)
    goal = @jar.reload.linked_goal
    goal.complete!
    reached = goal.reload.completed_amount

    refresh(@jar, title: "Next round", goal: 5_000_000)
    assert_equal :unchanged, sync(@jar)
    goal.reload
    assert_equal [ "completed", "Відпустка", BigDecimal("20000"), reached ], [ goal.state, goal.name, goal.target_amount, goal.completed_amount ]
    assert_equal [ BigDecimal("50000"), "Next round" ], @jar.jar_goal_link.values_at(:synced_target, :synced_title)

    goal.reopen!
    assert_equal :unchanged, sync(@jar), "the change seen while closed is not replayed"
    assert_equal [ "Відпустка", BigDecimal("20000") ], [ goal.reload.name, goal.target_amount ]

    goal.archive!
    refresh(@jar, title: "Next round", goal: 6_000_000)
    assert_equal :unchanged, sync(@jar)
    assert_equal BigDecimal("20000"), goal.reload.target_amount
  end

  # Review finding: a refused target also blocked the rename and errored on every sync
  test "a target the goal refuses is passed once, and the rename still goes through" do
    sync(@jar)
    goal = @jar.reload.linked_goal
    goal.update_columns(consumed_amount: 15_000)
    refresh(@jar, title: "Renamed", goal: 1_000_000)

    assert_difference -> { jar_goal_logs.where(level: "warn").count } => 1 do
      assert_no_difference -> { jar_goal_logs.where(level: "error").count } do
        assert_equal :updated, sync(@jar)
        3.times { assert_equal :unchanged, sync(@jar) }
      end
    end
    assert_equal [ "Renamed", BigDecimal("20000") ], [ goal.reload.name, goal.target_amount ]
    assert_equal BigDecimal("10000"), @jar.jar_goal_link.synced_target, "not tried again until monobank's target moves"

    refresh(@jar, title: "Renamed", goal: 1_800_000)
    assert_equal :updated, sync(@jar)
    assert_equal BigDecimal("18000"), goal.reload.target_amount
  end

  # Review finding: a write that keeps failing logged an error on every hourly sync
  test "a failure to write the goal is logged once a day, does not fail the sync and is retried" do
    sync(@jar)
    refresh(@jar, title: "Renamed", goal: 2_000_000)
    Goal.any_instance.stubs(:save!).raises(ActiveRecord::StatementInvalid, "boom")

    with_cache do
      assert_difference -> { jar_goal_logs.where(level: "error").count } => 1 do
        3.times { assert_equal :skipped, sync(@jar) }
      end
    end
    assert_equal "Відпустка", @jar.jar_goal_link.synced_title, "the change is tried again next sync"

    Goal.any_instance.unstub(:save!)
    assert_equal :updated, sync(@jar)
    assert_equal "Renamed", @jar.reload.linked_goal.name
  end

  # Review finding: deleting a goal and a sync writing it took the two rows in opposite orders
  test "deleting a goal locks the jar's link row before the goal's own rows" do
    sync(@jar)
    goal = @jar.reload.linked_goal
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] if payload[:sql].match?(/\A\s*(SELECT .* FOR UPDATE|DELETE|UPDATE)/m) }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { goal.destroy! }

    first = statements.index { |sql| sql.include?("monobank_jar_goal_links") }
    goal_rows = statements.index { |sql| sql.match?(/goal_accounts|goal_pledges|"goals"/) }
    assert first && goal_rows && first < goal_rows, "link row first, got:\n#{statements.join("\n")}"
  end

  private

    def sync(product)
      MonobankAccount::JarGoal.new(product.reload).sync
    end

    def jar_goal_logs
      DebugLogEntry.where(category: MonobankAccount::JarGoal::LOG_CATEGORY)
    end

    # The test environment's cache keeps nothing; the once-a-day logs need one that does
    def with_cache
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      yield
    ensure
      Rails.unstub(:cache)
    end

    # The next client-info for this jar
    def refresh(product, title:, goal:)
      product.reload.upsert_monobank_snapshot!(
        id: product.account_id, kind: "jar", currencyCode: CURRENCY_CODES.fetch(product.currency),
        balance: product.raw_balance_minor, creditLimit: 0, title: title, goal: goal
      )
    end
end
