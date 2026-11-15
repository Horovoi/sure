require "test_helper"

class ImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @import = imports(:transaction)
    @account = accounts(:depository)
  end

  test "publish_later starts the import once; a second publish raises and enqueues nothing" do
    Import.any_instance.stubs(:publishable?).returns(true)

    assert_enqueued_jobs 1, only: ImportJob do
      @import.publish_later

      assert_raises(AASM::InvalidTransition) { @import.publish_later }
      assert_raises(AASM::InvalidTransition) { Import.find(@import.id).publish_later }
    end

    assert @import.reload.importing?
  end

  test "a complete import cannot be published again" do
    configure_csv(@import)
    @import.publish
    assert @import.reload.complete?

    assert_raises(AASM::InvalidTransition) { @import.publish_later }
  end

  test "publish does nothing for an import that is reverting" do
    @import.update_column(:status, "reverting")
    @import.expects(:import!).never

    @import.publish

    assert @import.reload.reverting?
  end

  test "an error after the import committed does not mark it failed" do
    configure_csv(@import)
    Family.any_instance.expects(:sync_later).raises(StandardError, "redis down")

    assert_difference -> { @account.entries.count }, 1 do
      @import.publish
    end

    assert @import.reload.complete?
    assert_nil @import.error
  end

  test "a failed publish rolls back its entries and records the error" do
    configure_csv(@import)
    @import.stubs(:complete_import!).raises(StandardError, "boom")

    assert_no_difference -> { Entry.count } do
      @import.publish
    end

    assert @import.reload.failed?
    assert_equal "boom", @import.error
  end

  test "publish records failure even when the import's configuration is invalid" do
    configure_csv(@import)
    @import.update_column(:rows_to_skip, 999) # invalid, as an upload saved with validate: false can be
    @import.stubs(:import!).raises(StandardError, "boom")

    @import.publish

    assert @import.reload.failed?
  end

  test "revert moves to reverted, not pending, and can be published again" do
    configure_csv(@import)
    @import.publish

    @import.revert_later
    assert @import.reload.reverting?
    @import.revert

    assert @import.reload.reverted?
    assert_equal 0, @import.entries.count
    assert @import.editable?
    assert_not_includes Import.pending, @import

    @import.publish
    assert @import.reload.complete?
  end

  test "revert_later refuses an import that is not complete" do
    assert_raises(Import::NotRevertableError) { @import.revert_later }
  end

  test "mark_stale ends each in-progress state" do
    { "importing" => "failed", "reverting" => "revert_failed", "processing" => "processing_failed" }.each do |from, to|
      @import.update_column(:status, from)
      @import.reload.mark_stale!

      assert_equal to, @import.reload.status
      assert_match(/Timed out/, @import.error)
    end
  end

  test "stale scope lists only in-progress imports older than the timeout" do
    @import.update_columns(status: "importing", updated_at: 1.hour.ago)
    imports(:trade).update_columns(status: "importing", updated_at: 1.minute.ago)
    imports(:account).update_columns(status: "complete", updated_at: 1.hour.ago)

    assert_equal [ @import ], Import.stale.to_a
  end

  test "editable, revertable and deletable follow the state" do
    expectations = {
      "pending" => [ true, false, true ],
      "failed" => [ true, false, true ],
      "reverted" => [ true, false, true ],
      "importing" => [ false, false, false ],
      "reverting" => [ false, false, false ],
      "complete" => [ false, true, false ],
      "revert_failed" => [ false, true, false ]
    }

    expectations.each do |state, (editable, revertable, deletable)|
      @import.update_column(:status, state)
      assert_equal editable, @import.editable?, "editable? in #{state}"
      assert_equal revertable, @import.revertable?, "revertable? in #{state}"
      assert_equal deletable, @import.deletable?, "deletable? in #{state}"
    end
  end

  test "sync_mappings leaves other imports' mappings alone" do
    other = imports(:trade)
    other_mapping = other.mappings.create!(type: "Import::CategoryMapping", key: "Other")

    configure_csv(@import, csv: "date,name,amount,category\n01/01/2024,Coffee,10,Food\n", category_col_label: "category")
    @import.sync_mappings

    assert Import::Mapping.exists?(other_mapping.id)
    assert_equal [ "Food" ], @import.mappings.categories.pluck(:key)
  end

  test "sync_mappings removes mapping types that no longer apply" do
    configure_csv(@import, account: nil, csv: "date,name,amount,account\n01/01/2024,Coffee,10,Checking\n", account_col_label: "account")
    @import.sync_mappings
    assert @import.mappings.accounts.any?

    @import.update!(account: @account)
    @import.sync_mappings

    assert_empty @import.mappings.accounts
  end

  test "reset_configuration! drops rows and mappings" do
    configure_csv(@import)
    @import.sync_mappings

    @import.reset_configuration!

    assert_equal 0, @import.rows_count
    assert_empty @import.rows
    assert_empty @import.mappings
    assert_not @import.configured?
  end

  test "revert keeps an account the import created when other data was added to it later" do
    @import.update_column(:status, "reverting")
    account = @import.family.accounts.create!(name: "Imported", balance: 0, currency: "USD", accountable: Depository.new, import: @import)
    account.entries.create!(date: Date.current, amount: 10, currency: "USD", name: "Imported txn", import: @import, entryable: Transaction.new)
    account.entries.create!(date: Date.current, amount: 20, currency: "USD", name: "Added later", entryable: Transaction.new)
    untouched = @import.family.accounts.create!(name: "Imported 2", balance: 0, currency: "USD", accountable: Depository.new, import: @import)

    @import.revert

    assert @import.reload.reverted?
    assert_nil account.reload.import_id
    assert_equal [ "Added later" ], account.entries.pluck(:name)
    assert_not Account.exists?(untouched.id)
  end

  test "deleting an import hands claimed entries back" do
    entry = @account.entries.create!(date: Date.new(2024, 1, 1), amount: 10, currency: "USD", name: "Coffee", notes: "mine", entryable: Transaction.new)
    @import.claim_entry!(entry)
    entry.update!(import: @import, notes: "from csv")

    @import.destroy!

    assert_nil entry.reload.import_id
    assert_equal "mine", entry.notes
  end

  test "CSV-only date formats are not offered as a global family preference" do
    assert_empty Import::CSV_ONLY_DATE_FORMATS & Family::DATE_FORMATS
    assert_empty Import::CSV_ONLY_DATE_FORMATS.map(&:last) & Family::DATE_FORMATS.map(&:last)
  end

  test "DD/MM/YY and DD.MM.YY rows parse" do
    import = configure_csv(imports(:transaction), csv: "date,name,amount\n15/05/24,Coffee,10\n", date_format: "%d/%m/%y")
    row = import.rows.first
    assert row.valid?, row.errors.full_messages.to_sentence
    assert_equal "2024-05-15", row.date_iso

    import = configure_csv(imports(:transaction), csv: "date,name,amount\n01.11.26,Coffee,10\n", date_format: "%d.%m.%y")
    row = import.rows.first
    assert row.valid?, row.errors.full_messages.to_sentence
    assert_equal "2026-11-01", row.date_iso
  end

  test "a 4-digit year under a 2-digit year format is a row error" do
    import = configure_csv(imports(:transaction), csv: "date,name,amount\n01.11.2025,Coffee,10\n", date_format: "%d.%m.%y")
    row = import.rows.first

    refute row.valid?
    assert row.errors.added?(:date, "must exactly match the format: %d.%m.%y")
    refute import.cleaned?
  end

  test "a 4-digit year format still accepts a trailing time" do
    import = configure_csv(imports(:transaction), csv: "date,name,amount\n01.11.2025 10:30,Coffee,10\n", date_format: "%d.%m.%Y")

    assert import.rows.first.valid?
  end

  private
    def configure_csv(import, account: @account, csv: "date,name,amount\n01/01/2024,Coffee,10\n", **labels)
      import.update!(
        account: account,
        raw_file_str: csv,
        date_col_label: "date",
        amount_col_label: "amount",
        name_col_label: "name",
        date_format: "%m/%d/%Y",
        **labels
      )
      import.generate_rows_from_csv
      import.reload
    end
end
