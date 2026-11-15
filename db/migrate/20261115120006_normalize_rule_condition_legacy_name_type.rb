# Rule conditions saved with the old condition type "name" crash the rules page
# (the registry knows it as "transaction_name"). Rule::Condition now maps the
# alias on save; this rewrites the rows already stored. No row is deleted.
class NormalizeRuleConditionLegacyNameType < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE rule_conditions
      SET condition_type = 'transaction_name'
      WHERE condition_type = 'name'
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "The legacy 'name' condition type is not restored"
  end
end
