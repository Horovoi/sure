require "test_helper"

class MonobankAccount::JarGoalTest < ActiveSupport::TestCase
  include MonobankTestHelper

  setup do
    setup_monobank_family
    @jar = create_monobank_product(account_id: "jar", kind: "jar", title: "Відпустка", balance: 150_000, goal: 2_000_000)
    @account = @item.create_linked_account!(monobank_account: @jar)
  end

  test "a linked jar with a target becomes a goal funded by the whole jar account" do
    assert_difference -> { Goal.count } => 1, -> { GoalAccount.count } => 1 do
      assert_equal :created, sync(@jar)
    end

    goal = @jar.reload.linked_goal
    assert_equal [ "Відпустка", BigDecimal("20000"), "UAH", "one_off", "fixed", "active" ],
                 [ goal.name, goal.target_amount, goal.currency, goal.kind, goal.target_mode, goal.state ]
    assert_equal @family, goal.family
    link = goal.goal_accounts.sole
    assert_equal @account, link.account
    assert link.whole_account?
    assert_equal [ BigDecimal("20000"), "Відпустка", nil ], [ @jar.goal_synced_target, @jar.goal_synced_title, @jar.goal_dismissed_at ]
  end

  test "syncing again makes nothing new" do
    sync(@jar)

    assert_no_difference [ "Goal.count", "GoalAccount.count" ] do
      assert_equal :unchanged, sync(@jar)
      assert_equal :unchanged, sync(@jar)
    end
  end

  test "the processor keeps the goal, so a jar linked before gets it on its next sync" do
    assert_nil @jar.reload.goal_id

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

    assert_no_difference "Goal.count" do
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

    assert_no_difference "Goal.count" do
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
    assert_equal BigDecimal("25000"), @jar.reload.goal_synced_target
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
    assert_equal "Карпати", @jar.reload.goal_synced_title
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
  end

  test "a goal the owner deleted is not made again" do
    sync(@jar)
    @jar.reload.linked_goal.destroy!
    assert_nil @jar.reload.goal_id, "the foreign key clears the link"

    assert_no_difference "Goal.count" do
      assert_equal :dismissed, sync(@jar)
      refresh(@jar, title: "Відпустка", goal: 3_000_000)
      assert_equal :dismissed, sync(@jar)
    end
    assert_not_nil @jar.reload.goal_dismissed_at
  end

  test "a jar whose account already funds another goal is skipped and logged" do
    other = @family.goals.new(name: "Own vacation goal", target_amount: 10_000, currency: "UAH")
    other.goal_accounts.build(account: @account, allocated_amount: 500)
    other.save!

    assert_no_difference "Goal.count" do
      assert_difference -> { DebugLogEntry.where(category: MonobankAccount::JarGoal::LOG_CATEGORY).count } => 1 do
        assert_equal :skipped, sync(@jar)
      end
    end
    entry = DebugLogEntry.where(category: MonobankAccount::JarGoal::LOG_CATEGORY).last
    assert_equal [ "info", @account.id, "Own vacation goal" ], [ entry.level, entry.account_id, entry.metadata["other_goal_name"] ]
    assert_nil @jar.reload.goal_id

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

  test "a failure to write the goal is logged and does not fail the sync" do
    sync(@jar)
    goal = @jar.reload.linked_goal
    goal.update_columns(consumed_amount: 22_000, target_amount: 30_000)
    refresh(@jar, title: "Відпустка", goal: 2_100_000)

    assert_equal :skipped, sync(@jar), "a target below what was spent is refused by the goal"
    assert_equal BigDecimal("30000"), goal.reload.target_amount
    assert DebugLogEntry.where(category: MonobankAccount::JarGoal::LOG_CATEGORY, level: "error").exists?
    assert_equal BigDecimal("20000"), @jar.reload.goal_synced_target, "the change is tried again next sync"
  end

  private

    def sync(product)
      MonobankAccount::JarGoal.new(product.reload).sync
    end

    # The next client-info for this jar
    def refresh(product, title:, goal:)
      product.reload.upsert_monobank_snapshot!(
        id: product.account_id, kind: "jar", currencyCode: CURRENCY_CODES.fetch(product.currency),
        balance: product.raw_balance_minor, creditLimit: 0, title: title, goal: goal
      )
    end
end
