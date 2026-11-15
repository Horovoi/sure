# Linked transfer fees (decision 21): a fee the bank charged for a transfer is an
# ordinary expense in the 'Fees' category that points at its transfer. The legs keep
# the principal. When the transfer goes away the database clears the link, so a fee
# whose transfer was removed stays as a plain expense (Transfer deletes the fees itself
# when the whole transfer is deleted).
class AddFeeTransferToTransactions < ActiveRecord::Migration[8.1]
  def change
    add_reference :transactions, :fee_transfer,
      type: :uuid,
      null: true,
      index: true,
      foreign_key: { to_table: :transfers, on_delete: :nullify }
  end
end
