require "test_helper"

# A bank connection keeps a linked account: statement imports into it are refused on
# every path (direct account, mapped account, publish, the assistant tool).
class Import::ProviderLinkedRefusalTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @linked = accounts(:depository)
    item = LunchflowItem.create!(family: @family, name: "Bank", api_key: "key")
    Account::ProviderLink.link!(account: @linked, provider_account: item.lunchflow_accounts.create!(name: "C", currency: "USD", account_id: "c"))
    @linked.reload
    @message = "#{@linked.name} is linked to Lunch Flow. Its transactions come from the bank connection, " \
               "so statement imports into it are turned off. Unlink the account to import a statement."
  end

  test "CSV, trade and PDF imports into a linked account are invalid" do
    %w[TransactionImport TradeImport PdfImport MintImport].each do |type|
      import = @family.imports.new(type: type, account: @linked)

      assert_not import.valid?, type
      assert_equal [ @message ], import.errors[:account], type
    end
  end

  test "imports into a manual account and imports without one are unaffected" do
    assert @family.imports.new(type: "TransactionImport", account: accounts(:credit_card)).valid?
    assert @family.imports.new(type: "AccountImport").valid?
    assert @family.imports.new(type: "CategoryImport").valid?
  end

  test "the legacy plaid link counts too" do
    import = @family.imports.new(type: "TransactionImport", account: accounts(:connected))

    assert_not import.valid?
    assert_match(/is linked to Plaid/, import.errors[:account].first)
  end

  test "publish_later refuses an import saved without validation" do
    import = imports(:transaction)
    import.account = @linked
    import.save!(validate: false)

    error = assert_raises(Import::ProviderLinkedAccountError) { import.publish_later }

    assert_equal @message, error.message
    assert import.reload.pending?
  end

  test "an import whose rows are mapped to a linked account is not publishable" do
    import = imports(:transaction)
    import.mappings.create!(type: "Import::AccountMapping", key: @linked.name, mappable: @linked)

    assert_equal [ @linked ], import.provider_linked_target_accounts
    assert_not import.publishable?
    assert_raises(Import::ProviderLinkedAccountError) { import.publish_later }
  end

  test "a publish that is already queued fails with the message and writes nothing" do
    import = imports(:transaction)
    import.mappings.create!(type: "Import::AccountMapping", key: @linked.name, mappable: @linked)
    import.update_column(:status, "importing")

    assert_no_difference -> { Entry.count } do
      import.publish
    end

    assert import.reload.failed?
    assert_equal @message, import.error
  end

  test "an account name in a file that names a linked account maps to it and the import is refused" do
    import = imports(:transaction)
    import.update!(account: nil)
    import.rows.create!(account: @linked.name, date: "01/01/2026", amount: "10", currency: "USD", name: "x")

    assert_equal @linked, Import::AccountMapping.mappables_by_key(import)[@linked.name]
    import.sync_mappings
    mapping = import.mappings.accounts.find_by!(key: @linked.name)
    assert_equal @linked, mapping.mappable
    assert_includes mapping.selectable_values.map(&:last), @linked.id

    assert_equal [ @linked ], import.provider_linked_target_accounts
    assert_not import.publishable?
    assert_no_difference -> { @family.accounts.where(name: @linked.name).count } do
      assert_raises(Import::ProviderLinkedAccountError) { import.publish_later }
    end
  end

  test "a manual account wins over a linked one of the same name" do
    manual = @family.accounts.create!(name: @linked.name, balance: 0, currency: "USD", accountable: Depository.new)
    import = imports(:transaction)
    import.rows.create!(account: @linked.name, date: "01/01/2026", amount: "10", currency: "USD", name: "x")

    assert_equal manual, Import::AccountMapping.mappables_by_key(import)[@linked.name]
  end

  test "reverting an import keeps the entries a provider claimed" do
    import = imports(:transaction)
    manual = accounts(:credit_card)
    kept = manual.entries.create!(date: Date.current, amount: 10, currency: "USD", name: "Claimed", import: import, entryable: Transaction.new)
    kept.transaction.update!(extra: { "provider_claim" => { "source" => "monobank", "import_id" => import.id } })
    gone = manual.entries.create!(date: Date.current, amount: 11, currency: "USD", name: "Imported", import: import, entryable: Transaction.new)
    import.update_columns(status: "reverting")

    import.revert

    assert import.reload.reverted?, import.error
    assert Entry.exists?(kept.id)
    assert_nil kept.reload.import_id
    assert_not Entry.exists?(gone.id)
  end

  test "the assistant tool cannot point a PDF import at a linked account" do
    pdf = @family.imports.create!(type: "PdfImport", date_format: "%m/%d/%Y")
    pdf.update_columns(status: "pending", ai_summary: "Summary", document_type: "bank_statement")

    result = Assistant::Function::ImportBankStatement.new(users(:family_admin)).call("pdf_import_id" => pdf.id, "account_id" => @linked.id)

    assert_not result[:success]
    assert_equal "provider_linked", result[:error]
    assert_equal Import.provider_linked_message(@linked), result[:message]
    assert_nil pdf.reload.account_id
  end
end
