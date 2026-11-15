# An account the user keeps out of every report and total (net worth, cash flow,
# budgets, investments, the AI read tools) while it stays active and listed on its
# own. Off by default, so no figure changes until the user turns it on.
class AddExcludeFromReportsToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :exclude_from_reports, :boolean, default: false, null: false
  end
end
