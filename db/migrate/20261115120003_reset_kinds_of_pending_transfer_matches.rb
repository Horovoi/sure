# An auto-matched transfer used to give both legs their transfer kinds (and an
# uncategorized outflow into an investment account the Investment Contributions category)
# the moment it was suggested. A pending match is now only a suggestion: the kinds come
# with the confirm event. This puts the legs of the pending matches made before back as
# they were: standard, and without the category the match set.
#
# It updates rows and deletes none. The down is a no-op: confirming a match sets the kinds
# again, and the pre-deploy backup is the rollback.
class ResetKindsOfPendingTransferMatches < ActiveRecord::Migration[8.1]
  TRANSFER_KINDS = %w[funds_movement cc_payment loan_payment investment_contribution].freeze

  def up
    pending_legs = <<~SQL.squish
      SELECT inflow_transaction_id FROM transfers WHERE status = 'pending'
      UNION
      SELECT outflow_transaction_id FROM transfers WHERE status = 'pending'
    SQL

    # The category first: it is recognised by the kind the next statement resets
    execute <<~SQL.squish
      UPDATE transactions
      SET category_id = NULL
      FROM entries, accounts, categories
      WHERE transactions.kind = 'investment_contribution'
        AND transactions.id IN (#{pending_legs})
        AND entries.entryable_type = 'Transaction' AND entries.entryable_id = transactions.id
        AND accounts.id = entries.account_id
        AND categories.id = transactions.category_id
        AND categories.family_id = accounts.family_id
        AND categories.name = #{connection.quote(investment_contributions_name)}
    SQL

    execute <<~SQL.squish
      UPDATE transactions
      SET kind = 'standard'
      WHERE kind IN (#{TRANSFER_KINDS.map { |kind| connection.quote(kind) }.join(", ")})
        AND id IN (#{pending_legs})
    SQL
  end

  def down
  end

  private
    # The name Family#investment_contributions_category looks up (the UI is English only)
    def investment_contributions_name
      I18n.t("models.category.investment_contributions", locale: :en, default: "Investment Contributions")
    end
end
