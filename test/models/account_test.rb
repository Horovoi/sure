require "test_helper"

class AccountTest < ActiveSupport::TestCase
  include SyncableInterfaceTest, EntriesTestHelper

  setup do
    @account = @syncable = accounts(:depository)
    @family = families(:dylan_family)
  end

  test "can destroy" do
    assert_difference "Account.count", -1 do
      @account.destroy
    end
  end

  test "create_and_sync calls sync_later by default" do
    Account.any_instance.expects(:sync_later).once

    account = Account.create_and_sync({
      family: @family,
      name: "Test Account",
      balance: 100,
      currency: "USD",
      accountable_type: "Depository",
      accountable_attributes: {}
    })

    assert account.persisted?
    assert_equal "USD", account.currency
    assert_equal 100, account.balance
  end

  test "create_and_sync skips sync_later when skip_initial_sync is true" do
    Account.any_instance.expects(:sync_later).never

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Linked Account",
        balance: 500,
        currency: "EUR",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true
    )

    assert account.persisted?
    assert_equal "EUR", account.currency
    assert_equal 500, account.balance
  end

  test "create_and_sync creates opening anchor with correct currency" do
    Account.any_instance.stubs(:sync_later)

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Test Account",
        balance: 1000,
        currency: "GBP",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true
    )

    opening_anchor = account.valuations.opening_anchor.first
    assert_not_nil opening_anchor
    assert_equal "GBP", opening_anchor.entry.currency
    assert_equal 1000, opening_anchor.entry.amount
  end

  test "create_and_sync uses provided opening balance date" do
    Account.any_instance.stubs(:sync_later)
    opening_date = 3.months.ago.to_date

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Test Account",
        balance: 1000,
        currency: "USD",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true,
      opening_balance_date: opening_date
    )

    opening_anchor = account.valuations.opening_anchor.first
    assert_equal opening_date, opening_anchor.entry.date
    assert_equal 1000, opening_anchor.entry.amount
  end

  test "create_and_sync keeps the entered current balance when it differs from the opening balance" do
    Account.any_instance.stubs(:sync_later)

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Student Loan",
        balance: 8_000,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: { initial_balance: 20_000, rate_type: "fixed", interest_rate: 4.5, term_months: 120 }
      },
      skip_initial_sync: true
    )

    assert_equal 20_000, account.valuations.opening_anchor.first.entry.amount
    # Without an anchor today, the first sync would walk forward from the opening
    # valuation and replace the entered 8,000 with 20,000.
    today_valuation = account.entries.valuations.find_by(date: Date.current)
    assert_not_nil today_valuation
    assert_equal 8_000, today_valuation.amount
    assert today_valuation.entryable.reconciliation?
  end

  test "create_and_sync leaves the opening anchor alone when the opening balance date is today" do
    Account.any_instance.stubs(:sync_later)

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Student Loan",
        balance: 8_000,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: { initial_balance: 20_000, rate_type: "fixed", interest_rate: 4.5, term_months: 120 }
      },
      skip_initial_sync: true,
      opening_balance_date: Date.current
    )

    valuations = account.entries.valuations.where(date: Date.current)
    assert_equal 1, valuations.count
    assert_equal 20_000, valuations.first.amount
    assert valuations.first.entryable.opening_anchor?
  end

  test "create_and_sync treats a blank initial balance as absent" do
    Account.any_instance.stubs(:sync_later)

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Student Loan",
        balance: 8_000,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: { initial_balance: "", rate_type: "fixed", interest_rate: 4.5, term_months: 120 }
      },
      skip_initial_sync: true
    )

    assert_equal 8_000, account.valuations.opening_anchor.first.entry.amount
    assert_nil account.entries.valuations.find_by(date: Date.current)
  end

  test "create_and_sync treats a zero initial balance as a real opening balance" do
    Account.any_instance.stubs(:sync_later)

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Student Loan",
        balance: 8_000,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: { initial_balance: 0, rate_type: "fixed", interest_rate: 4.5, term_months: 120 }
      },
      skip_initial_sync: true
    )

    assert_equal 0, account.valuations.opening_anchor.first.entry.amount
    assert_equal 8_000, account.entries.valuations.find_by(date: Date.current)&.amount
  end

  test "a later entry before the start date moves the opening anchor, not the today anchor" do
    Account.any_instance.stubs(:sync_later)
    opening_date = 1.month.ago.to_date

    account = Account.create_and_sync(
      {
        family: @family,
        name: "Car Loan",
        balance: 8_000,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: { initial_balance: 10_000 }
      },
      skip_initial_sync: true,
      opening_balance_date: opening_date
    )
    create_transaction(account: account, date: opening_date - 10.days, amount: 100)

    assert account.move_opening_anchor_before_oldest_entry!
    assert_equal opening_date - 11.days, account.valuations.opening_anchor.first.entry.date
    assert_equal 8_000, account.entries.valuations.find_by(date: Date.current).amount
  end

  {
    "Depository" => "savings",
    "Investment" => "brokerage",
    "Crypto" => "wallet",
    "Loan" => "mortgage",
    "Property" => "single_family_home"
  }.each do |type, subtype|
    test "#{type} subtype persists on create when it comes after the type" do
      Account.any_instance.stubs(:sync_later)

      account = Account.create_and_sync({
        family: @family,
        name: "#{type} account",
        balance: 100,
        currency: "USD",
        accountable_type: type,
        subtype: subtype
      })

      assert account.persisted?
      assert_equal subtype, account.reload.subtype
    end

    test "#{type} subtype persists on create when it comes before the type" do
      Account.any_instance.stubs(:sync_later)

      # The order account_params permits them in
      account = Account.create_and_sync({
        family: @family,
        name: "#{type} account",
        balance: 100,
        subtype: subtype,
        currency: "USD",
        accountable_type: type
      })

      assert account.persisted?
      assert_equal subtype, account.reload.subtype
      assert_kind_of type.constantize, account.accountable
    end
  end

  test "subtype assigned before the accountable is built is not dropped" do
    account = Account.new
    account.accountable_type = "Depository"
    account.subtype = "checking"

    assert_not_nil account.accountable
    assert_equal "checking", account.subtype
  end

  test "subtype assigned before accountable_type is not dropped" do
    account = Account.new
    account.subtype = "savings"
    account.accountable_type = "Depository"

    assert_kind_of Depository, account.accountable
    assert_equal "savings", account.accountable.subtype
  end

  test "subtype and nested accountable attributes land on one accountable" do
    account = Account.new(
      family: @family, name: "Mortgage", balance: 100, currency: "USD",
      subtype: "mortgage", accountable_type: "Loan",
      accountable_attributes: { interest_rate: 4.5 }
    )

    assert_equal "mortgage", account.accountable.subtype
    assert_equal 4.5, account.accountable.interest_rate
  end

  test "gets short/long subtype label" do
    investment = Investment.new(subtype: "hsa")
    account = @family.accounts.create!(
      name: "Test Investment",
      balance: 1000,
      currency: "USD",
      accountable: investment
    )

    assert_equal "HSA", account.short_subtype_label
    assert_equal "Health Savings Account", account.long_subtype_label

    # Test with nil subtype
    account.accountable.update!(subtype: nil)
    assert_equal "Investments", account.short_subtype_label
    assert_equal "Investments", account.long_subtype_label
  end

  # Tax treatment tests (TaxTreatable concern)

  test "tax_treatment delegates to accountable for Investment" do
    investment = Investment.new(subtype: "401k")
    account = @family.accounts.create!(
      name: "Test 401k",
      balance: 1000,
      currency: "USD",
      accountable: investment
    )

    assert_equal :tax_deferred, account.tax_treatment
    assert_equal I18n.t("accounts.tax_treatments.tax_deferred"), account.tax_treatment_label
  end

  test "tax_treatment delegates to accountable for Crypto" do
    crypto = Crypto.new(tax_treatment: :taxable)
    account = @family.accounts.create!(
      name: "Test Crypto",
      balance: 500,
      currency: "USD",
      accountable: crypto
    )

    assert_equal :taxable, account.tax_treatment
    assert_equal I18n.t("accounts.tax_treatments.taxable"), account.tax_treatment_label
  end

  test "tax_treatment returns nil for non-investment accounts" do
    # Depository accounts don't have tax_treatment
    assert_nil @account.tax_treatment
    assert_nil @account.tax_treatment_label
  end

  test "tax_advantaged? returns true for tax-advantaged accounts" do
    investment = Investment.new(subtype: "401k")
    account = @family.accounts.create!(
      name: "Test 401k",
      balance: 1000,
      currency: "USD",
      accountable: investment
    )

    assert account.tax_advantaged?
    assert_not account.taxable?
  end

  test "tax_advantaged? returns false for taxable accounts" do
    investment = Investment.new(subtype: "brokerage")
    account = @family.accounts.create!(
      name: "Test Brokerage",
      balance: 1000,
      currency: "USD",
      accountable: investment
    )

    assert_not account.tax_advantaged?
    assert account.taxable?
  end

  test "taxable? returns true for accounts without tax_treatment" do
    # Depository accounts
    assert @account.taxable?
    assert_not @account.tax_advantaged?
  end

  test "visible_status_sql matches the visible scope" do
    assert_equal %q("a".status IN ('draft','active')), Account.visible_status_sql("a")
    assert_equal Account.visible.pluck(:id).sort, Account.where(Account.visible_status_sql).pluck(:id).sort
  end

  test "an account type from params must be a known account type" do
    error = assert_raises(ArgumentError) do
      Account.new(family: @family, name: "x", balance: 0, currency: "USD", accountable_type: "Kernel", accountable_attributes: {})
    end
    assert_match "Unknown account type", error.message

    account = Account.new(family: @family, name: "x", balance: 0, currency: "USD", accountable_type: "Depository", accountable_attributes: {})
    assert_kind_of Depository, account.accountable
  end

  test "disabling stamps disabled_at and enabling clears it" do
    travel_to Time.zone.local(2026, 3, 9, 12) do
      @account.disable!
      assert_equal Time.current, @account.reload.disabled_at
    end

    @account.enable!
    assert_nil @account.reload.disabled_at
  end

  test "activating a disabled account clears disabled_at" do
    @account.disable!
    assert_not_nil @account.reload.disabled_at

    @account.activate!
    assert_nil @account.reload.disabled_at
  end

  test "a failed deletion stamps disabled_at" do
    @account.mark_for_deletion!
    assert_nil @account.disabled_at

    travel_to Time.zone.local(2026, 3, 9, 12) do
      @account.recover_from_failed_destroy!
      assert @account.reload.disabled?
      assert_equal Time.current, @account.disabled_at
    end
  end

  test "a failed deletion of a disabled account keeps the day it was disabled" do
    disabled_at = Time.zone.local(2026, 3, 1, 12)
    travel_to(disabled_at) { @account.disable! }
    @account.mark_for_deletion!

    travel_to Time.zone.local(2026, 3, 9, 12) do
      @account.recover_from_failed_destroy!
    end

    assert @account.reload.disabled?
    assert_equal disabled_at, @account.disabled_at
  end

  test "counted_in_history holds active and disabled accounts, not drafts or deletions" do
    active = @family.accounts.create!(name: "Active", balance: 0, currency: "USD", accountable: Depository.new)
    disabled = @family.accounts.create!(name: "Disabled", balance: 0, currency: "USD", accountable: Depository.new)
    draft = @family.accounts.create!(name: "Draft", balance: 0, currency: "USD", accountable: Property.new, status: "draft")
    deleting = @family.accounts.create!(name: "Deleting", balance: 0, currency: "USD", accountable: Depository.new)
    disabled.disable!
    deleting.mark_for_deletion!

    ids = @family.accounts.counted_in_history.pluck(:id)

    assert_includes ids, active.id
    assert_includes ids, disabled.id
    assert_not_includes ids, draft.id
    assert_not_includes ids, deleting.id
  end
end
