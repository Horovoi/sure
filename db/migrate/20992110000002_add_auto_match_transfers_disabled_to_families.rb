# The switch on the preferences page: a family can turn transfer auto-matching off.
# Stored as the opt-out, so every existing family keeps matching.
class AddAutoMatchTransfersDisabledToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :auto_match_transfers_disabled, :boolean, null: false, default: false
  end
end
