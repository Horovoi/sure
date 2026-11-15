# One transaction keeps at most one pledge (w2-goals goal-pledges). The pledge id sits
# in transactions.extra["goal"]["pledge_id"], beside the fork's other extra keys
# (exchange_rate, replaced_subscription_charge). Concurrent, so its own file.
class AddGoalPledgeIndexToTransactions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :transactions,
              "((extra -> 'goal' ->> 'pledge_id'))",
              unique: true,
              where: "(extra -> 'goal' ->> 'pledge_id') IS NOT NULL",
              name: "ix_transactions_extra_goal_pledge_id",
              algorithm: :concurrently
  end
end
