require "test_helper"

class TransactionImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper, ImportInterfaceTest

  setup do
    @subject = @import = imports(:transaction)
  end

  test "uploaded? if raw_file_str is present" do
    @import.expects(:raw_file_str).returns("test").once
    assert @import.uploaded?
  end

  test "configured? if uploaded and rows are generated" do
    @import.expects(:uploaded?).returns(true).once
    @import.expects(:rows_count).returns(1).once
    assert @import.configured?
  end

  test "cleaned? if rows are generated and valid" do
    @import.expects(:configured?).returns(true).once
    assert @import.cleaned?
  end

  test "publishable? if cleaned and mappings are valid" do
    @import.expects(:cleaned?).returns(true).once
    assert @import.publishable?
  end

  test "imports transactions, categories, tags, and accounts" do
    import = <<~CSV
      date,name,amount,category,tags,account,notes
      01/01/2024,Txn1,100,TestCategory1,TestTag1,TestAccount1,notes1
      01/02/2024,Txn2,200,TestCategory2,TestTag1|TestTag2,TestAccount2,notes2
      01/03/2024,Txn3,300,,,,notes3
    CSV

    @import.update!(
      raw_file_str: import,
      date_col_label: "date",
      amount_col_label: "amount",
      date_format: "%m/%d/%Y"
    )

    @import.generate_rows_from_csv

    @import.mappings.create! key: "TestCategory1", create_when_empty: true, type: "Import::CategoryMapping"
    @import.mappings.create! key: "TestCategory2", mappable: categories(:food_and_drink), type: "Import::CategoryMapping"
    @import.mappings.create! key: "", create_when_empty: false, mappable: nil, type: "Import::CategoryMapping" # Leaves uncategorized

    @import.mappings.create! key: "TestTag1", create_when_empty: true, type: "Import::TagMapping"
    @import.mappings.create! key: "TestTag2", mappable: tags(:one), type: "Import::TagMapping"
    @import.mappings.create! key: "", create_when_empty: false, mappable: nil, type: "Import::TagMapping" # Leaves untagged

    @import.mappings.create! key: "TestAccount1", create_when_empty: true, type: "Import::AccountMapping"
    @import.mappings.create! key: "TestAccount2", mappable: accounts(:depository), type: "Import::AccountMapping"
    @import.mappings.create! key: "", mappable: accounts(:depository), type: "Import::AccountMapping"

    @import.reload

    assert_difference -> { Entry.count } => 3,
                      -> { Transaction.count } => 3,
                      -> { Tag.count } => 1,
                      -> { Category.count } => 1,
                      -> { Account.count } => 1 do
      @import.publish
    end

    assert_equal "complete", @import.status
  end

  test "imports transactions with separate type column for signage convention" do
    import = <<~CSV
      date,amount,amount_type
      01/01/2024,100,debit
      01/02/2024,200,credit
      01/03/2024,300,debit
    CSV

    @import.update!(
      account: accounts(:depository),
      raw_file_str: import,
      date_col_label: "date",
      date_format: "%m/%d/%Y",
      amount_col_label: "amount",
      entity_type_col_label: "amount_type",
      amount_type_inflow_value: "debit",
      amount_type_strategy: "custom_column",
      signage_convention: nil # Explicitly set to nil to prove this is not needed
    )

    @import.generate_rows_from_csv

    @import.reload

    assert_difference -> { Entry.count } => 3,
                      -> { Transaction.count } => 3 do
      @import.publish
    end

    assert_equal [ -100, 200, -300 ], @import.entries.order(:date).map(&:amount)
  end

  test "does not create duplicate when matching transaction exists with same name" do
    account = accounts(:depository)

    # Create an existing manual transaction
    existing_entry = account.entries.create!(
      date: Date.new(2024, 1, 1),
      amount: 100,
      currency: "USD",
      name: "Coffee Shop",
      entryable: Transaction.new(category: categories(:food_and_drink))
    )

    # Try to import a CSV with the same transaction
    import_csv = <<~CSV
      date,name,amount
      01/01/2024,Coffee Shop,100
    CSV

    @import.update!(
      account: account,
      raw_file_str: import_csv,
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      date_format: "%m/%d/%Y",
      amount_type_strategy: "signed_amount",
      signage_convention: "inflows_negative"
    )

    @import.generate_rows_from_csv
    @import.reload

    # Should not create a new entry, should update the existing one
    assert_no_difference -> { Entry.count } do
      assert_no_difference -> { Transaction.count } do
        @import.publish
      end
    end

    # The existing entry should now be linked to the import
    assert_equal @import.id, existing_entry.reload.import_id
  end

  test "skips a row the account already records under another name, without claiming it" do
    account = accounts(:depository)

    # A hand-entered transaction, two days off and under another name
    existing_entry = account.entries.create!(
      date: Date.new(2024, 1, 3),
      amount: 100,
      currency: "USD",
      name: "Coffee Shop",
      notes: "typed by hand",
      entryable: Transaction.new
    )

    import_csv = <<~CSV
      date,name,amount
      01/01/2024,CARD 1234 COFFEE SHOP KYIV,100
      01/01/2024,Bakery,25
    CSV

    @import.update!(
      account: account,
      raw_file_str: import_csv,
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      date_format: "%m/%d/%Y",
      amount_type_strategy: "signed_amount",
      signage_convention: "inflows_negative"
    )

    @import.generate_rows_from_csv
    @import.reload

    skipped_row = @import.rows.find_by!(name: "CARD 1234 COFFEE SHOP KYIV")
    assert_equal({ skipped_row.id => existing_entry }, @import.already_recorded)
    assert_equal 1, @import.dry_run[:transactions]

    assert_difference -> { Entry.count } => 1,
                      -> { Transaction.count } => 1 do
      @import.publish
    end

    assert_equal [ "Bakery" ], @import.entries.pluck(:name)
    existing_entry.reload
    assert_nil existing_entry.import_id
    assert_equal "typed by hand", existing_entry.notes
    assert_not existing_entry.import_locked
    assert_empty @import.claimed_entries
  end

  test "a row 4 days from an existing entry is imported" do
    account = accounts(:depository)
    account.entries.create!(date: Date.new(2024, 1, 5), amount: 100, currency: "USD", name: "Coffee Shop", entryable: Transaction.new)

    @import.update!(
      account: account,
      raw_file_str: "date,name,amount\n01/01/2024,Coffee,100\n",
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      date_format: "%m/%d/%Y",
      amount_type_strategy: "signed_amount",
      signage_convention: "inflows_negative"
    )
    @import.generate_rows_from_csv
    @import.reload

    assert_empty @import.already_recorded
    assert_difference -> { Entry.count } => 1 do
      @import.publish
    end
  end

  test "an exact-name claim wins over the windowed match and an entry is used once" do
    account = accounts(:depository)
    exact = account.entries.create!(date: Date.new(2024, 1, 1), amount: 100, currency: "USD", name: "Coffee Shop", entryable: Transaction.new)
    nearby = account.entries.create!(date: Date.new(2024, 1, 2), amount: 100, currency: "USD", name: "Typed by hand", entryable: Transaction.new)

    @import.update!(
      account: account,
      raw_file_str: "date,name,amount\n01/01/2024,Coffee Shop,100\n01/01/2024,Coffee Shop,100\n01/01/2024,Coffee Shop,100\n",
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      date_format: "%m/%d/%Y",
      amount_type_strategy: "signed_amount",
      signage_convention: "inflows_negative"
    )
    @import.generate_rows_from_csv
    @import.reload

    # Row 1 claims the exact entry, row 2 is skipped against the nearby one, row 3 is new
    assert_equal [ nearby ], @import.already_recorded.values

    assert_difference -> { Entry.count } => 1 do
      @import.publish
    end

    assert_equal @import.id, exact.reload.import_id
    assert_nil nearby.reload.import_id
    assert_equal [ exact.id ], @import.claimed_entries.pluck(:entry_id)
  end

  test "rows mapped to different accounts are matched per account" do
    checking = accounts(:depository)
    card = accounts(:credit_card)
    card_entry = card.entries.create!(date: Date.new(2024, 1, 2), amount: 100, currency: "USD", name: "Card coffee", entryable: Transaction.new)

    @import.update!(
      raw_file_str: "date,name,amount,account\n01/01/2024,Coffee,100,Checking\n01/01/2024,Coffee,100,Card\n",
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      account_col_label: "account",
      date_format: "%m/%d/%Y",
      amount_type_strategy: "signed_amount",
      signage_convention: "inflows_negative"
    )
    @import.generate_rows_from_csv
    @import.mappings.create!(key: "Checking", mappable: checking, type: "Import::AccountMapping")
    @import.mappings.create!(key: "Card", mappable: card, type: "Import::AccountMapping")
    @import.reload

    card_row = @import.rows.find_by!(account: "Card")
    assert_equal({ card_row.id => card_entry }, @import.already_recorded)

    assert_difference -> { checking.entries.count } => 1, -> { card.entries.count } => 0 do
      @import.publish
    end
  end

  test "imports all identical transactions from CSV even when one exists in database" do
    account = accounts(:depository)

    # Create an existing manual transaction
    existing_entry = account.entries.create!(
      date: Date.new(2024, 1, 1),
      amount: 50,
      currency: "USD",
      name: "Vending Machine",
      entryable: Transaction.new
    )

    # Import CSV with 3 identical transactions (e.g., buying from vending machine 3 times)
    import_csv = <<~CSV
      date,name,amount
      01/01/2024,Vending Machine,50
      01/01/2024,Vending Machine,50
      01/01/2024,Vending Machine,50
    CSV

    @import.update!(
      account: account,
      raw_file_str: import_csv,
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      date_format: "%m/%d/%Y",
      amount_type_strategy: "signed_amount",
      signage_convention: "inflows_negative"
    )

    @import.generate_rows_from_csv
    @import.reload

    # Should update 1 existing and create 2 new (total of 3 in system)
    # The first matching row claims the existing entry, the other 2 create new ones
    assert_difference -> { Entry.count } => 2,
                      -> { Transaction.count } => 2 do
      @import.publish
    end

    # Should have exactly 3 identical transactions total
    assert_equal 3, account.entries.where(
      date: Date.new(2024, 1, 1),
      amount: 50,
      name: "Vending Machine"
    ).count

    # The existing entry should be linked to the import
    assert_equal @import.id, existing_entry.reload.import_id
  end

  test "imports all identical transactions from CSV when none exist in database" do
    account = accounts(:depository)

    # Import CSV with 3 identical transactions (no existing entry in database)
    import_csv = <<~CSV
      date,name,amount
      01/01/2024,Vending Machine,50
      01/01/2024,Vending Machine,50
      01/01/2024,Vending Machine,50
    CSV

    @import.update!(
      account: account,
      raw_file_str: import_csv,
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      date_format: "%m/%d/%Y",
      amount_type_strategy: "signed_amount",
      signage_convention: "inflows_negative"
    )

    @import.generate_rows_from_csv
    @import.reload

    # Should create all 3 as new transactions
    assert_difference -> { Entry.count } => 3,
                      -> { Transaction.count } => 3 do
      @import.publish
    end

    # Should have exactly 3 identical transactions
    assert_equal 3, account.entries.where(
      date: Date.new(2024, 1, 1),
      amount: 50,
      name: "Vending Machine"
    ).count
  end

  test "uses family currency as fallback when account has no currency and no CSV currency column" do
    account = accounts(:depository)
    family = account.family

    # Clear the account's currency to simulate an account without currency set
    account.update_column(:currency, nil)

    import_csv = <<~CSV
      date,name,amount
      01/01/2024,Test Transaction,100
    CSV

    @import.update!(
      account: account,
      raw_file_str: import_csv,
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      date_format: "%m/%d/%Y",
      amount_type_strategy: "signed_amount",
      signage_convention: "inflows_negative"
    )

    @import.generate_rows_from_csv
    @import.reload

    assert_difference -> { Entry.count } => 1 do
      @import.publish
    end

    # The transaction should have the family's currency as fallback
    entry = @import.entries.first
    assert_equal family.currency, entry.currency
  end

  test "does not raise error when all accounts are properly mapped" do
    # Import CSV with multiple accounts, all mapped
    import_csv = <<~CSV
      date,name,amount,account
      01/01/2024,Coffee Shop,100,Checking Account
      01/02/2024,Grocery Store,200,Credit Card
    CSV

    checking = accounts(:depository)
    credit_card = accounts(:credit_card)

    @import.update!(
      account: nil,
      raw_file_str: import_csv,
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      account_col_label: "account",
      date_format: "%m/%d/%Y",
      amount_type_strategy: "signed_amount",
      signage_convention: "inflows_negative"
    )

    @import.generate_rows_from_csv

    # Map both accounts
    @import.mappings.create!(key: "Checking Account", mappable: checking, type: "Import::AccountMapping")
    @import.mappings.create!(key: "Credit Card", mappable: credit_card, type: "Import::AccountMapping")
    @import.mappings.create!(key: "", mappable: nil, create_when_empty: false, type: "Import::CategoryMapping")
    @import.mappings.create!(key: "", mappable: nil, create_when_empty: false, type: "Import::TagMapping")

    @import.reload

    # Should succeed without errors
    assert_difference -> { Entry.count } => 2,
                      -> { Transaction.count } => 2 do
      @import.publish
    end

    assert_equal "complete", @import.status

    # Check that each account got one entry from this import
    assert_equal 1, checking.entries.where(import: @import).count
    assert_equal 1, credit_card.entries.where(import: @import).count
  end

  test "skips specified number of rows" do
    account = accounts(:depository)
    import_csv = <<~CSV
      Some Metadata provided by bank
      Generated on 2024-01-01
      date,name,amount
      01/01/2024,Transaction 1,100
      01/02/2024,Transaction 2,200
    CSV

    @import.update!(
      account: account,
      raw_file_str: import_csv,
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      date_format: "%m/%d/%Y",
      amount_type_strategy: "signed_amount",
      signage_convention: "inflows_negative",
      rows_to_skip: 2
    )

    @import.generate_rows_from_csv
    @import.reload

    # helper to check rows - assuming 2 valid rows
    assert_equal 2, @import.rows.count

    # Sort to ensure order
    rows = @import.rows.order(date: :asc)

    assert_equal "Transaction 1", rows.first.name
    assert_equal "100", rows.first.amount
  end

  test "revert hands a claimed manual entry back with its category, tags and notes" do
    account = accounts(:depository)
    existing_entry = account.entries.create!(
      date: Date.new(2024, 1, 1),
      amount: 100,
      currency: "USD",
      name: "Coffee Shop",
      notes: "typed by hand",
      entryable: Transaction.new(category: categories(:food_and_drink), tags: [ tags(:one) ])
    )

    configure_claiming_import(account, "01/01/2024,Coffee Shop,100,Income,Trips|Emergency fund,from csv")
    @import.sync_mappings
    @import.publish

    assert @import.reload.complete?
    existing_entry.reload
    assert_equal @import.id, existing_entry.import_id
    assert_equal "from csv", existing_entry.notes

    @import.revert_later
    assert_no_difference -> { Entry.count } do
      @import.revert
    end

    assert @import.reload.reverted?
    existing_entry.reload
    assert_nil existing_entry.import_id
    assert_equal "typed by hand", existing_entry.notes
    assert_not existing_entry.import_locked
    assert_equal categories(:food_and_drink), existing_entry.transaction.category
    assert_equal [ tags(:one) ], existing_entry.transaction.tags.to_a
    assert_empty @import.claimed_entries
  end

  test "revert works after a claimed entry's earlier category and tag were deleted" do
    account = accounts(:depository)
    category = account.family.categories.create!(name: "Short lived", color: "#000000", classification: "expense", lucide_icon: "shapes")
    tag = account.family.tags.create!(name: "Short lived")
    existing_entry = account.entries.create!(
      date: Date.new(2024, 1, 1), amount: 100, currency: "USD", name: "Coffee Shop",
      entryable: Transaction.new(category: category, tags: [ tag, tags(:one) ])
    )

    configure_claiming_import(account, "01/01/2024,Coffee Shop,100,Income,Trips,from csv")
    @import.sync_mappings
    @import.publish
    assert @import.reload.complete?

    category.destroy!
    tag.destroy!

    @import.revert_later
    @import.revert

    assert @import.reload.reverted?
    assert_nil existing_entry.transaction.reload.category
    assert_equal [ tags(:one) ], existing_entry.transaction.tags.to_a
  end

  test "revert returns an entry claimed from an earlier import to that import" do
    account = accounts(:depository)
    earlier = imports(:trade)
    earlier.update_column(:status, "complete")
    entry = account.entries.create!(date: Date.new(2024, 1, 1), amount: 100, currency: "USD", name: "Coffee Shop", import: earlier, entryable: Transaction.new)

    configure_claiming_import(account, "01/01/2024,Coffee Shop,100,,,")
    @import.publish
    assert_equal @import.id, entry.reload.import_id

    @import.revert_later
    @import.revert

    assert_equal earlier.id, entry.reload.import_id
  end

  test "publish schedules the subscription charge reconciler" do
    configure_claiming_import(accounts(:depository), "01/05/2024,Streaming,15,,,")

    assert_enqueued_with(job: RecurringTransaction::ReconcileJob) do
      @import.publish
    end
    assert @import.reload.complete?
  end

  test "revert restores the generated charge an imported entry replaced and keeps next_expected_date" do
    account = accounts(:depository)
    # 4 days apart: outside the already-recorded window (3 days), so the import creates its own entry
    recurring, generated = subscription_charge(account, Date.new(2024, 1, 1))
    configure_claiming_import(account, "01/05/2024,Streaming service,15,,,")
    @import.publish
    imported = @import.reload.entries.sole
    assert imported.transaction.replace_subscription_charge!(generated, source: "test")
    next_expected = recurring.reload.next_expected_date

    @import.revert_later
    @import.revert

    assert @import.reload.reverted?
    assert_not Entry.exists?(imported.id)
    restored = account.entries.where(source: "subscription").sole
    assert_equal Date.new(2024, 1, 1), restored.date
    assert_equal recurring.id, restored.transaction.recurring_transaction_id
    # An import revert does not mark the pair: a new import of the statement may match it again
    assert_not restored.transaction.potential_duplicate_dismissed?
    assert_equal next_expected, recurring.reload.next_expected_date
  end

  test "an entry the import only claimed keeps what it replaced on revert" do
    account = accounts(:depository)
    _recurring, generated = subscription_charge(account, Date.new(2024, 1, 3))
    existing = account.entries.create!(date: Date.new(2024, 1, 1), amount: 100, currency: "USD", name: "Coffee Shop", entryable: Transaction.new)
    assert existing.transaction.replace_subscription_charge!(generated, source: "test")

    configure_claiming_import(account, "01/01/2024,Coffee Shop,100,,,")
    @import.publish
    assert_equal @import.id, existing.reload.import_id

    @import.revert_later
    assert_no_difference -> { Entry.count } do
      @import.revert
    end

    assert existing.reload.transaction.replaced_subscription_charge?
    assert_not account.entries.where(source: "subscription").exists?
  end

  private
    def subscription_charge(account, date)
      recurring = account.family.recurring_transactions.create!(
        name: "Streaming service", amount: 15, currency: "USD", expected_day_of_month: date.day,
        last_occurrence_date: date, next_expected_date: date.next_month,
        status: "active", subscription_state: "subscription", default_account: account
      )
      generated = account.entries.create!(
        date: date, amount: 15, currency: "USD", name: "Streaming service", source: "subscription",
        entryable: Transaction.new(recurring_transaction: recurring)
      )
      [ recurring, generated ]
    end

    def configure_claiming_import(account, row)
      @import.update!(
        account: account,
        raw_file_str: "date,name,amount,category,tags,notes\n#{row}\n",
        date_col_label: "date",
        amount_col_label: "amount",
        name_col_label: "name",
        category_col_label: "category",
        tags_col_label: "tags",
        notes_col_label: "notes",
        date_format: "%m/%d/%Y",
        amount_type_strategy: "signed_amount",
        signage_convention: "inflows_negative"
      )
      @import.generate_rows_from_csv
      @import.reload
    end
end
