require "test_helper"

class Assistant::Function::SetOpeningBalanceTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @fn = Assistant::Function::SetOpeningBalance.new(@user)
    Account::OpeningBalanceManager.new(@account).set_opening_balance(balance: 1000, date: 1.year.ago.to_date)
  end

  test "is a destructive, idempotent tool on accounts" do
    assert_equal :destructive, @fn.scope_tag
    assert @fn.idempotent?
    assert_equal "Account", @fn.record_type
  end

  test "sets the balance and date and reports the effect" do
    result = @fn.call("account_id" => @account.id, "balance" => 1500, "date" => 6.months.ago.to_date.iso8601)

    assert_equal @account.id, result[:id]
    assert result[:changed]
    assert_equal "1000.0", result.dig(:before, :balance)
    assert_equal "1500.0", result.dig(:after, :balance)
    assert_equal 1500, Account.find(@account.id).opening_anchor_balance
    assert_equal 6.months.ago.to_date, Account.find(@account.id).opening_anchor_date
  end

  test "a balance update after the opening date pins the current balance" do
    result = @fn.call("account_id" => @account.id, "balance" => 1500, "dry_run" => true)

    # The depository fixture has a reconciliation four days ago
    assert_equal false, result.dig(:current_balance, :changes)
    assert_match "pins", result.dig(:current_balance, :reason)
  end

  test "dry_run writes nothing" do
    assert_no_changes -> { Account.find(@account.id).opening_anchor_balance } do
      result = @fn.call("account_id" => @account.id, "balance" => 5, "dry_run" => true)
      assert result[:dry_run]
    end
  end

  test "audit_before has the opening balance and the current balance" do
    before = @fn.audit_before("account_id" => @account.id)

    assert_equal "1000.0", before.dig(:opening, :balance)
    assert_equal @account.balance.to_s("F"), before[:current_balance]
  end

  test "refuses a date on or after the oldest other entry, a blank date and a linked account" do
    oldest = @account.entries.where.not(id: anchor_entry.id).minimum(:date)

    result = @fn.call("account_id" => @account.id, "balance" => 1, "date" => oldest.iso8601)
    assert_equal "invalid_date", result[:error]
    assert_equal oldest, result[:oldest_entry_date]

    assert_equal "invalid_date", @fn.call("account_id" => @account.id, "balance" => 1, "date" => "")[:error]
    assert_equal "linked_account", @fn.call("account_id" => accounts(:connected).id, "balance" => 1)[:error]
    assert_equal "invalid_balance", @fn.call("account_id" => @account.id, "balance" => "lots")[:error]
    assert_equal "not_found", @fn.call("account_id" => SecureRandom.uuid, "balance" => 1)[:error]
  end

  private
    def anchor_entry
      @account.valuations.opening_anchor.includes(:entry).first.entry
    end
end
