require "test_helper"

class TransferTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @outflow = transactions(:transfer_out)
    @inflow = transactions(:transfer_in)
  end

  test "transfer destroyed if either transaction is destroyed" do
    assert_difference [ "Transfer.count", "Transaction.count", "Entry.count" ], -1 do
      @outflow.entry.destroy
    end
  end

  test "transfer has different accounts, opposing amounts, and within 4 days of each other" do
    outflow_entry = create_transaction(date: 1.day.ago.to_date, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)

    assert_difference -> { Transfer.count } => 1 do
      Transfer.create!(
        inflow_transaction: inflow_entry.transaction,
        outflow_transaction: outflow_entry.transaction,
      )
    end
  end

  test "transfer cannot have 2 transactions from the same account" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: 1.day.ago.to_date, account: accounts(:depository), amount: -500)

    transfer = Transfer.new(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction,
    )

    assert_no_difference -> { Transfer.count } do
      transfer.save
    end

    assert_equal "Must be from different accounts", transfer.errors.full_messages.first
  end

  test "Transfer transactions must have opposite amounts" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -400)

    transfer = Transfer.new(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction,
    )

    assert_no_difference -> { Transfer.count } do
      transfer.save
    end

    assert_equal "Must have opposite amounts", transfer.errors.full_messages.first
  end

  test "transfer dates must be within 4 days of each other" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: 5.days.ago.to_date, account: accounts(:credit_card), amount: -500)

    transfer = Transfer.new(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction,
    )

    assert_no_difference -> { Transfer.count } do
      transfer.save
    end

    assert_equal "Must be within 4 days", transfer.errors.full_messages.first
  end

  test "transfer must be from the same family" do
    family1 = families(:empty)
    family2 = families(:dylan_family)

    family1_account = family1.accounts.create!(name: "Family 1 Account", balance: 5000, currency: "USD", accountable: Depository.new)
    family2_account = family2.accounts.create!(name: "Family 2 Account", balance: 5000, currency: "USD", accountable: Depository.new)

    outflow_txn = create_transaction(date: Date.current, account: family1_account, amount: 500)
    inflow_txn = create_transaction(date: Date.current, account: family2_account, amount: -500)

    transfer = Transfer.new(
      inflow_transaction: inflow_txn.transaction,
      outflow_transaction: outflow_txn.transaction,
    )

    assert transfer.invalid?
    assert_equal "Must be from same family", transfer.errors.full_messages.first
  end

  test "transaction can only belong to one transfer" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry1 = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)
    inflow_entry2 = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)

    Transfer.create!(inflow_transaction: inflow_entry1.transaction, outflow_transaction: outflow_entry.transaction)

    assert_raises ActiveRecord::RecordInvalid do
      Transfer.create!(inflow_transaction: inflow_entry2.transaction, outflow_transaction: outflow_entry.transaction)
    end
  end

  test "outflow kind depends on the destination account, and on the source for investments" do
    depository = accounts(:depository)

    assert_equal "investment_contribution", Transfer.outflow_kind_for(source_account: depository, destination_account: accounts(:investment))
    assert_equal "investment_contribution", Transfer.outflow_kind_for(source_account: depository, destination_account: accounts(:crypto))
    assert_equal "loan_payment", Transfer.outflow_kind_for(source_account: depository, destination_account: accounts(:loan))
    assert_equal "cc_payment", Transfer.outflow_kind_for(source_account: depository, destination_account: accounts(:credit_card))
    assert_equal "cc_payment", Transfer.outflow_kind_for(source_account: depository, destination_account: accounts(:other_liability))
    assert_equal "funds_movement", Transfer.outflow_kind_for(source_account: accounts(:investment), destination_account: depository)
    assert_equal "funds_movement", Transfer.outflow_kind_for(source_account: accounts(:investment), destination_account: accounts(:crypto))
    assert_equal "funds_movement", Transfer.outflow_kind_for(source_account: accounts(:credit_card), destination_account: depository)
  end

  test "creating a confirmed transfer sets the kinds of both legs from the accounts" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:loan), amount: -500)

    Transfer.create!(inflow_transaction: inflow_entry.transaction, outflow_transaction: outflow_entry.transaction, status: "confirmed")

    assert_equal "loan_payment", outflow_entry.transaction.reload.kind
    assert_equal "funds_movement", inflow_entry.transaction.reload.kind
  end

  test "deleting one leg resets the other leg to standard" do
    @outflow.entry.destroy!

    assert_equal "standard", @inflow.reload.kind
  end

  test "deleting one leg through bulk destroy resets the other leg" do
    Entry.where(id: @inflow.entry.id).destroy_all

    assert_equal "standard", @outflow.reload.kind
  end

  test "destroying a transfer resets both legs and clears the investment contributions category" do
    family = families(:dylan_family)
    category = ensure_investment_contributions_category(family)
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:investment), amount: -500)
    transfer = Transfer.create!(inflow_transaction: inflow_entry.transaction, outflow_transaction: outflow_entry.transaction, status: "confirmed")

    assert_equal category, outflow_entry.transaction.reload.category

    transfer.destroy!

    assert_equal "standard", outflow_entry.transaction.reload.kind
    assert_nil outflow_entry.transaction.category
    assert_equal "standard", inflow_entry.transaction.reload.kind
  end

  test "reject records a rejection and resets the legs" do
    transfer = transfers(:one)

    assert_difference -> { RejectedTransfer.count } => 1, -> { Transfer.count } => -1 do
      transfer.reject!
    end

    assert_equal "standard", @inflow.reload.kind
    assert_equal "standard", @outflow.reload.kind
  end

  test "pairing a rejected pair again clears the rejection" do
    transfers(:one).reject!

    assert_difference -> { RejectedTransfer.count } => -1 do
      Transfer.create!(inflow_transaction: @inflow, outflow_transaction: @outflow, status: "confirmed")
    end
  end

  test "confirm moves a pending transfer to confirmed and only once" do
    transfer = transfers(:one)
    assert transfer.pending?

    transfer.confirm!

    assert transfer.reload.confirmed?
    assert_not transfer.may_confirm?
    assert_raises(AASM::InvalidTransition) { transfer.confirm! }
  end

  test "a transfer whose leg was edited later can still be confirmed and annotated" do
    transfer = transfers(:one)
    @inflow.entry.update!(amount: -90, date: 20.days.ago.to_date)

    transfer.confirm!
    transfer.update!(notes: "edited")

    assert transfer.reload.confirmed?
    assert_equal "edited", transfer.notes
  end

  # --- Kinds only on confirm (w2-transfers transfer-match-policy, decision 20) ---

  test "a pending transfer leaves both legs as they were" do
    transfer = create_pending_transfer(from: accounts(:depository), to: accounts(:credit_card))

    assert transfer.pending?
    assert_equal "standard", transfer.outflow_transaction.reload.kind
    assert_equal "standard", transfer.inflow_transaction.reload.kind
  end

  test "confirm sets both legs' kinds from the destination account" do
    transfer = create_pending_transfer(from: accounts(:depository), to: accounts(:credit_card))

    transfer.confirm!

    assert transfer.reload.confirmed?
    assert_equal "cc_payment", transfer.outflow_transaction.reload.kind
    assert_equal "funds_movement", transfer.inflow_transaction.reload.kind
  end

  test "confirm gives an uncategorized outflow into an investment account the contributions category" do
    category = ensure_investment_contributions_category(families(:dylan_family))
    transfer = create_pending_transfer(from: accounts(:depository), to: accounts(:investment))

    assert_nil transfer.outflow_transaction.reload.category

    transfer.confirm!

    outflow = transfer.outflow_transaction.reload
    assert_equal "investment_contribution", outflow.kind
    assert_equal category, outflow.category
  end

  test "confirm keeps an outflow category the user set" do
    ensure_investment_contributions_category(families(:dylan_family))
    transfer = create_pending_transfer(from: accounts(:depository), to: accounts(:investment))
    transfer.outflow_transaction.update!(category: categories(:food_and_drink))

    transfer.confirm!

    assert_equal categories(:food_and_drink), transfer.outflow_transaction.reload.category
  end

  test "a failed confirm leaves the transfer pending and the legs unchanged" do
    transfer = create_pending_transfer(from: accounts(:depository), to: accounts(:credit_card))
    Transaction.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(Transaction.new))

    assert_raises(ActiveRecord::RecordInvalid) { transfer.confirm! }

    assert transfer.reload.pending?
  end

  test "reject resets the kinds of a confirmed transfer" do
    transfer = create_pending_transfer(from: accounts(:depository), to: accounts(:credit_card))
    transfer.confirm!

    transfer.reject!

    assert_equal "standard", transfer.outflow_transaction.reload.kind
    assert_equal "standard", transfer.inflow_transaction.reload.kind
  end

  test "reject keeps a one-time mark the user put on a leg of a pending match" do
    transfer = create_pending_transfer(from: accounts(:depository), to: accounts(:credit_card))
    transfer.outflow_transaction.update!(kind: "one_time")

    transfer.reject!

    assert_equal "one_time", transfer.outflow_transaction.reload.kind
    assert_equal "standard", transfer.inflow_transaction.reload.kind
  end

  test "destroy resets the kinds of a confirmed transfer" do
    transfer = create_pending_transfer(from: accounts(:depository), to: accounts(:loan))
    transfer.confirm!
    assert_equal "loan_payment", transfer.outflow_transaction.reload.kind

    transfer.destroy!

    assert_equal "standard", transfer.outflow_transaction.reload.kind
    assert_equal "standard", transfer.inflow_transaction.reload.kind
  end

  private
    def create_pending_transfer(from:, to:)
      outflow_entry = create_transaction(date: Date.current, account: from, amount: 500)
      inflow_entry = create_transaction(date: Date.current, account: to, amount: -500)

      Transfer.create!(inflow_transaction: inflow_entry.transaction, outflow_transaction: outflow_entry.transaction)
    end
end
