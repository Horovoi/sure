require "test_helper"

class Assistant::Function::RecordBalanceTest < ActiveSupport::TestCase
  SOURCE = "Monobank app, card balance screen".freeze

  setup do
    @user = users(:family_admin)
    @fn = Assistant::Function::RecordBalance.new(@user)
  end

  test "is a destructive, idempotent tool on accounts" do
    assert_equal :destructive, @fn.scope_tag
    assert @fn.idempotent?
    assert_equal "Account", @fn.record_type
  end

  test "a non-cash manual account gets a balance update today with the citation in its notes" do
    account = accounts(:property)

    result = nil
    assert_difference -> { account.entries.where(entryable_type: "Valuation").count }, 1 do
      result = @fn.call("account_id" => account.id, "balance" => 600_000, "source" => "Valuation report 2026-11-10 (appraiser)")
    end

    entry = Entry.find(result[:entry_id])
    assert_equal account.id, result[:id]
    assert_equal "balance_update_today", result[:recorded_as]
    assert_equal Date.current, entry.date
    assert entry.entryable.reconciliation?
    assert_equal 600_000, entry.amount
    assert_equal "Valuation report 2026-11-10 (appraiser)", entry.notes
    assert_equal 600_000, account.reload.balance
  end

  test "a cash account tracked by transactions gets its opening balance adjusted, cited in its notes" do
    account = accounts(:credit_card)
    Account::OpeningBalanceManager.new(account).set_opening_balance(balance: 0, date: 1.year.ago.to_date)

    result = @fn.call("account_id" => account.id, "balance" => 1234, "source" => SOURCE)

    assert_equal "opening_balance_adjusted", result[:recorded_as]
    entry = Entry.find(result[:entry_id])
    assert entry.entryable.opening_anchor?
    assert_includes entry.notes, SOURCE
    assert_equal 1234, account.reload.balance
  end

  test "a person's note stays and the same citation is not added twice" do
    account = accounts(:property)
    @fn.call("account_id" => account.id, "balance" => 1, "source" => SOURCE)
    entry = account.entries.where(entryable_type: "Valuation").find_by(date: Date.current)
    entry.update!(notes: "Checked by hand")

    @fn.call("account_id" => account.id, "balance" => 2, "source" => SOURCE)
    @fn.call("account_id" => account.id, "balance" => 2, "source" => SOURCE)

    assert_equal "Checked by hand\n\n#{SOURCE}", entry.reload.notes
  end

  test "a citation is required" do
    account = accounts(:property)

    assert_no_difference -> { Entry.count } do
      assert_equal "source_required", @fn.call("account_id" => account.id, "balance" => 1)[:error]
      assert_equal "source_required", @fn.call("account_id" => account.id, "balance" => 1, "source" => " ab ")[:error]
      assert_equal "source_required", @fn.call("account_id" => account.id, "balance" => 1, "source" => "x" * 501)[:error]
    end
  end

  test "only manual accounts of the family" do
    assert_equal "linked_account", @fn.call("account_id" => accounts(:connected).id, "balance" => 1, "source" => SOURCE)[:error]
    assert_equal "not_found", @fn.call("account_id" => SecureRandom.uuid, "balance" => 1, "source" => SOURCE)[:error]
    assert_equal "invalid_balance", @fn.call("account_id" => accounts(:property).id, "balance" => "NaN", "source" => SOURCE)[:error]
  end

  test "audit_before has the balance, the opening balance and today's valuation" do
    account = accounts(:property)

    before = @fn.audit_before("account_id" => account.id)

    assert_equal account.balance.to_s("F"), before[:balance]
    assert_nil before[:valuation_today]
  end
end
