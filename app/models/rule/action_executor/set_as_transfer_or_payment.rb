class Rule::ActionExecutor::SetAsTransferOrPayment < Rule::ActionExecutor
  def type
    "select"
  end

  def options
    family.accounts.alphabetically.pluck(:name, :id)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    target_account = family.accounts.find_by_id(value)
    return 0 unless target_account

    count_modified_resources(transaction_scope.with_entry) do |transaction|
      # Check the Transfer row, not the kind: an investment contribution leg is a transfer
      # even though Transaction#transfer? is false for it.
      next false if transaction.transfer.present?
      next false if target_account.id == transaction.entry.account_id

      transfer = build_transfer(target_account, transaction.entry)

      # The legs' kinds (and the Investment Contributions category) are set by Transfer's after_create.
      begin
        Transfer.transaction(requires_new: true) { transfer.save! }
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        Rails.logger.info("Rule could not make transaction #{transaction.id} a transfer: #{e.message}")
        next false
      end

      transfer.sync_account_later
      true
    end
  end

  private
    def build_transfer(target_account, entry)
      missing_transaction = Transaction.new(
        entry: target_account.entries.build(
          amount: entry.amount * -1,
          currency: entry.currency,
          date: entry.date,
          name: "#{target_account.liability? ? 'Payment' : 'Transfer'} #{entry.amount.negative? ? "to #{target_account.name}" : "from #{entry.account.name}"}",
          user_modified: true
        )
      )

      transfer = Transfer.find_or_initialize_by(
        inflow_transaction: entry.amount.positive? ? missing_transaction : entry.transaction,
        outflow_transaction: entry.amount.positive? ? entry.transaction : missing_transaction
      )
      transfer.status = "confirmed"
      transfer
    end
end
