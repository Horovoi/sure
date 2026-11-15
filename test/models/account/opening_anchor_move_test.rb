require "test_helper"

# An entry older than the opening balance moves the opening balance earlier, so the
# entry counts and today's balance includes it (decision BA8, 14 Nov 2026).
class Account::OpeningAnchorMoveTest < ActiveSupport::TestCase
  setup do
    @account = families(:dylan_family).accounts.create!(
      name: "Anchor test", balance: 1000, currency: "USD", accountable: Depository.new
    )
    @anchor_date = 10.days.ago.to_date
    assert @account.set_opening_anchor_balance(balance: 1000, date: @anchor_date).success?
  end

  test "an entry older than the opening balance moves it to the day before and counts" do
    add_expense(100, date: 20.days.ago.to_date)

    sync_balances

    assert_equal 21.days.ago.to_date, @account.reload.opening_anchor_date
    assert_equal 1000, @account.opening_anchor_balance
    assert_equal 900, @account.balance
  end

  test "an entry on the opening date also moves it" do
    add_expense(50, date: @anchor_date)

    sync_balances

    assert_equal @anchor_date - 1.day, @account.reload.opening_anchor_date
    assert_equal 950, @account.balance
  end

  test "entries after the opening balance leave it where it is" do
    add_expense(100, date: 5.days.ago.to_date)

    sync_balances

    assert_equal @anchor_date, @account.reload.opening_anchor_date
    assert_equal 900, @account.balance
  end

  test "linked accounts keep their opening balance" do
    add_expense(100, date: 20.days.ago.to_date)
    @account.stubs(:manual?).returns(false)
    @account.stubs(:linked?).returns(true)
    @account.stubs(:synced_by_enabled_provider?).returns(true)

    Account::Syncer.new(@account).perform_sync(nil)

    assert_equal @anchor_date, Account.find(@account.id).opening_anchor_date
  end

  private
    def add_expense(amount, date:)
      @account.entries.create!(
        date: date, name: "Expense", amount: amount, currency: "USD",
        entryable: Transaction.new
      )
    end

    def sync_balances
      Account::Syncer.new(@account).perform_sync(nil)
    end
end
