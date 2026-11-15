require "test_helper"
require "ostruct"

class PdfImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository) # USD
    @import = @family.imports.create!(type: "PdfImport", date_format: "%m/%d/%Y")
    @import.update_columns(status: "pending", ai_summary: "Summary", document_type: "bank_statement")
    # Rows are extracted before the account is chosen; inflows_positive: "-50" is a 50 outflow
    @coffee = add_row(date: "03/10/2024", amount: "-50", name: "CARD COFFEE")
    @salary = add_row(date: "03/12/2024", amount: "1200", name: "SALARY")
    @import.update!(account: @account)
  end

  test "already_recorded is empty until an account is chosen" do
    @account.entries.create!(date: Date.new(2024, 3, 10), amount: 50, currency: "USD", name: "Coffee", entryable: Transaction.new)
    @import.update!(account: nil)

    assert_empty @import.already_recorded
    assert_equal 2, @import.new_rows_count
  end

  test "publishing skips rows the account already records and creates the rest" do
    existing = @account.entries.create!(date: Date.new(2024, 3, 11), amount: 50, currency: "USD", name: "Coffee", entryable: Transaction.new)

    assert_equal({ @coffee.id => existing }, @import.already_recorded)
    assert_equal 1, @import.new_rows_count

    assert_difference -> { Entry.count } => 1 do
      @import.publish
    end

    assert @import.reload.complete?
    assert_equal [ "SALARY" ], @import.entries.pluck(:name)
    assert_nil existing.reload.import_id
    assert_equal({ @coffee.id => existing }, PdfImport.find(@import.id).already_recorded)
  end

  test "an entry added between review and publish is caught at publish" do
    assert_empty @import.already_recorded

    added = @account.entries.create!(date: Date.new(2024, 3, 12), amount: -1200, currency: "USD", name: "Salary", entryable: Transaction.new)
    importing = PdfImport.find(@import.id)

    assert_difference -> { Entry.count } => 1 do
      importing.publish
    end

    assert importing.reload.complete?
    assert_equal [ "CARD COFFEE" ], importing.entries.pluck(:name)
    assert_nil added.reload.import_id
  end

  test "revert leaves matched entries unchanged" do
    existing = @account.entries.create!(date: Date.new(2024, 3, 10), amount: 50, currency: "USD", name: "Coffee", notes: "with Anna", entryable: Transaction.new(category: categories(:food_and_drink)))
    existing.transaction.tags = [ tags(:one) ]
    @coffee.update_column(:category, "Restaurants")

    @import.publish
    assert @import.reload.complete?
    assert_nil existing.reload.import_id

    @import.revert_later
    @import.revert

    assert @import.reload.reverted?
    assert_empty @import.entries
    existing.reload
    assert_nil existing.import_id
    assert_equal categories(:food_and_drink), existing.transaction.category
    assert_equal [ tags(:one) ], existing.transaction.tags.to_a
    assert_equal "with Anna", existing.notes
    assert_not existing.import_locked
  end

  test "an import whose every row is already recorded publishes and completes with no entries" do
    @account.entries.create!(date: Date.new(2024, 3, 10), amount: 50, currency: "USD", name: "Coffee", entryable: Transaction.new)
    @account.entries.create!(date: Date.new(2024, 3, 12), amount: -1200, currency: "USD", name: "Salary", entryable: Transaction.new)

    assert @import.publishable?
    assert_equal 0, @import.new_rows_count

    assert_no_difference -> { Entry.count } do
      @import.publish
    end

    assert @import.reload.complete?
    assert_empty @import.entries
    assert_equal 2, PdfImport.find(@import.id).already_recorded.size
  end

  test "a category used only by skipped rows is not created" do
    @account.entries.create!(date: Date.new(2024, 3, 10), amount: 50, currency: "USD", name: "Coffee", entryable: Transaction.new)
    @coffee.update_column(:category, "Brand new category")
    @import.sync_mappings
    assert @import.mappings.categories.find_by!(key: "Brand new category").create_when_empty

    assert_no_difference -> { @family.categories.count } do
      @import.publish
    end
  end

  test "extract_transactions stores string keys so rows are generated without a reload" do
    provider = mock("provider")
    response = OpenStruct.new(
      success?: true,
      data: { transactions: [ { date: "2024-03-10", amount: "-50", name: "Coffee" } ], period: { start_date: "2024-03-01" } }
    )
    provider.expects(:extract_bank_statement).returns(response)
    Provider::Registry.stubs(:get_provider).with(:openai).returns(provider)
    @import.stubs(:pdf_file_content).returns("%PDF-1.4")

    @import.extract_transactions

    assert @import.has_extracted_transactions?
    assert_equal "Coffee", @import.extracted_transactions.first["name"]

    @import.generate_rows_from_extracted_data
    assert_equal 1, @import.rows_count
    assert_equal [ "Coffee" ], @import.rows.pluck(:name)
  end

  test "regenerating rows twice on the same record does not keep old rows" do
    @import.update!(extracted_data: { "transactions" => [ { "date" => "2024-03-10", "amount" => "-50", "name" => "Coffee" } ] })
    @import.rows.load

    @import.generate_rows_from_extracted_data
    @import.generate_rows_from_extracted_data

    assert_equal 1, @import.reload.rows_count
    assert_equal 1, @import.rows.count
  end

  test "statement balance check matches both balances" do
    with_statement(opening: 1000, closing: "1 150,00")
    set_balance(@account, Date.new(2024, 2, 29), 1000)
    set_balance(@account, Date.new(2024, 3, 31), 1150.004)

    opening, closing = PdfImport.find(@import.id).statement_balance_check

    assert_equal :opening, opening.side
    assert_equal Date.new(2024, 3, 1), opening.date
    assert_equal :match, opening.status
    assert_equal :closing, closing.side
    assert_equal :match, closing.status
    assert_equal Money.new(1150, "USD"), closing.statement_amount
  end

  test "statement balance check reports the difference when a balance does not match" do
    with_statement(opening: 1000, closing: 1150)
    set_balance(@account, Date.new(2024, 2, 29), 1000)
    set_balance(@account, Date.new(2024, 3, 31), 1100)

    opening, closing = PdfImport.find(@import.id).statement_balance_check

    assert_equal :match, opening.status
    assert_equal :mismatch, closing.status
    assert_equal Money.new(1100, "USD"), closing.account_amount
    assert_equal Money.new(-50, "USD"), closing.difference
  end

  test "statement balance check uses the start balance of the first day when the day before has no balance" do
    with_statement(opening: 1000, closing: 1000)
    set_balance(@account, Date.new(2024, 3, 1), 1000)
    set_balance(@account, Date.new(2024, 3, 31), 1000)

    opening, _closing = PdfImport.find(@import.id).statement_balance_check

    assert_equal :match, opening.status
  end

  test "statement balance check is missing when the statement has no period or balance" do
    @import.update!(extracted_data: { "period" => { "end_date" => "2024-03-31" }, "closing_balance" => nil })

    opening, closing = PdfImport.find(@import.id).statement_balance_check

    assert_equal :missing, opening.status
    assert_nil opening.date
    assert_equal :missing, closing.status
    assert_nil closing.account_amount
  end

  test "statement balance check is empty without an account and treats an unparseable amount as missing" do
    with_statement(opening: "n/a", closing: 1150)

    assert_equal :missing, PdfImport.find(@import.id).statement_balance_check.first.status

    @import.update!(account: nil)
    assert_empty PdfImport.find(@import.id).statement_balance_check
  end

  test "statement balance check is not synced when the account has no balance for the day yet" do
    with_statement(opening: 1000, closing: 1150)
    set_balance(@account, Date.new(2024, 2, 29), 1000)

    opening, closing = PdfImport.find(@import.id).statement_balance_check

    assert_equal :match, opening.status
    assert_equal :not_synced, closing.status
    assert_nil closing.account_amount
  end

  test "statement balance check waits while the account is syncing" do
    with_statement(opening: 1000, closing: 1150)
    set_balance(@account, Date.new(2024, 2, 29), 1000)
    set_balance(@account, Date.new(2024, 3, 31), 1150)
    @account.syncs.create!(status: "pending")

    assert_equal [ :not_synced, :not_synced ], PdfImport.find(@import.id).statement_balance_check.map(&:status)
  end

  test "statement balance check compares liability balances by absolute value" do
    card = accounts(:credit_card)
    @import.update!(account: card)
    with_statement(opening: -500, closing: -650.5)
    set_balance(card, Date.new(2024, 2, 29), 500)
    set_balance(card, Date.new(2024, 3, 31), 650.5)

    opening, closing = PdfImport.find(@import.id).statement_balance_check

    assert_equal :match, opening.status
    assert_equal :match, closing.status
    assert_equal Money.new(650.5, "USD"), closing.statement_amount
  end

  test "publish schedules the subscription charge reconciler" do
    RecurringTransaction::ReconcileJob.expects(:schedule_for).with(@family).once

    @import.publish

    assert @import.reload.complete?
  end

  test "revert restores the generated charge an imported row replaced" do
    recurring = @family.recurring_transactions.create!(
      name: "Card coffee club", amount: 45, currency: "USD", expected_day_of_month: 8,
      last_occurrence_date: Date.new(2024, 3, 8), next_expected_date: Date.new(2024, 4, 8),
      status: "active", subscription_state: "subscription", default_account: @account
    )
    generated = @account.entries.create!(
      # Another amount, so the statement's duplicate matcher does not skip the coffee row
      date: Date.new(2024, 3, 8), amount: 45, currency: "USD", name: "Card coffee club", source: "subscription",
      entryable: Transaction.new(recurring_transaction: recurring)
    )
    @import.publish
    imported = @import.reload.entries.find_by!(name: "CARD COFFEE")
    assert imported.transaction.replace_subscription_charge!(generated, source: "test")

    @import.revert_later
    @import.revert

    assert @import.reload.reverted?
    restored = @account.entries.where(source: "subscription").sole
    assert_equal Date.new(2024, 3, 8), restored.date
    assert_equal recurring.id, restored.transaction.recurring_transaction_id
    assert_equal Date.new(2024, 4, 8), recurring.reload.next_expected_date
  end

  private
    def add_row(date:, amount:, name:)
      @import.rows.create!(date: date, amount: amount, name: name, currency: "USD")
    end

    def with_statement(opening:, closing:, start_date: "2024-03-01", end_date: "2024-03-31")
      @import.update!(extracted_data: {
        "period" => { "start_date" => start_date, "end_date" => end_date },
        "opening_balance" => opening,
        "closing_balance" => closing,
        "transactions" => []
      })
    end

    # end_balance is a generated column: with no flows it equals the start balance
    def set_balance(account, date, amount)
      account.balances.where(date: date).delete_all
      account.balances.create!(date: date, balance: amount, currency: account.currency, start_cash_balance: amount, cash_balance: amount)
    end
end
