# When an account entered disabled (decision 25). Past net worth counts a disabled
# account only for the days before this. Cleared on enable. No backfill: production
# has no disabled accounts, and a disabled account without a stamp falls back to
# its updated_at.
class AddDisabledAtToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :disabled_at, :datetime
  end
end
