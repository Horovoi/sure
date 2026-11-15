require "test_helper"

# w2-transfers transfer-tags-counterpart: a transfer leg's row names the other account
class Transactions::TransferCounterpartViewTest < ActionView::TestCase
  setup do
    @checking = accounts(:depository)
    @savings = accounts(:connected)
  end

  test "an outflow leg points to the destination account" do
    outflow_entry, _inflow_entry = transfer_entries

    html = render(partial: "transactions/transaction", locals: { entry: outflow_entry, balance_trend: nil, view_ctx: "global" })

    assert_includes html, "#{@checking.name} → #{@savings.name}"
  end

  test "an inflow leg points back to the source account" do
    _outflow_entry, inflow_entry = transfer_entries

    html = render(partial: "transactions/transaction", locals: { entry: inflow_entry, balance_trend: nil, view_ctx: "global" })

    assert_includes html, "#{@savings.name} ← #{@checking.name}"
  end

  test "a transfer kind without a transfer names its own account only" do
    entry = @checking.entries.create!(name: "Unmatched", amount: 100, currency: "USD", date: Date.current, entryable: Transaction.new(kind: "funds_movement"))

    html = render(partial: "transactions/transaction", locals: { entry: entry, balance_trend: nil, view_ctx: "global" })

    assert_includes html, @checking.name
    assert_not_includes html, "→"
    assert_not_includes html, "←"
  end

  private
    def transfer_entries
      outflow = Transaction.new
      outflow_entry = @checking.entries.create!(name: "Transfer to Savings", amount: 100, currency: "USD", date: Date.current, entryable: outflow)
      inflow = Transaction.new
      inflow_entry = @savings.entries.create!(name: "Transfer from Checking", amount: -100, currency: "USD", date: Date.current, entryable: inflow)
      Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed")

      [ outflow_entry.reload, inflow_entry.reload ]
    end
end
