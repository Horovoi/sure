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

  private
    def add_row(date:, amount:, name:)
      @import.rows.create!(date: date, amount: amount, name: name, currency: "USD")
    end
end
