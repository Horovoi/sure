# Envelope budgets (w3-envelope): a per-category opt-in to carry the unspent amount
# into the next period, and the carried amount, written by Budget::RolloverCalculator.
class AddEnvelopeRolloverToBudgetCategories < ActiveRecord::Migration[8.1]
  def change
    add_column :budget_categories, :rollover_enabled, :boolean, null: false, default: false
    add_column :budget_categories, :rolled_over_amount, :decimal, precision: 19, scale: 4, null: false, default: 0

    # Only leftovers carry (decision 34): an overspend carries 0, never a debt. A negative
    # carry would quietly lower what a category has to spend, so the database refuses it
    # whatever the writer.
    add_check_constraint :budget_categories, "rolled_over_amount >= 0",
                         name: "chk_budget_categories_rolled_over_amount_non_negative"
  end
end
