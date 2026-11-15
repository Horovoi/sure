require "test_helper"

# Statement imports into an account a bank connection keeps are refused with a clear
# message on every way in: new import, account choice, upload, publish, account menu.
class ImportsProviderLinkedTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    @linked = accounts(:depository)
    item = LunchflowItem.create!(family: @user.family, name: "Bank", api_key: "key")
    Account::ProviderLink.link!(account: @linked, provider_account: item.lunchflow_accounts.create!(name: "C", currency: "USD", account_id: "c"))
    @message = Import.provider_linked_message(@linked.reload)
  end

  test "a new CSV or trade import into a linked account is not created" do
    %w[TransactionImport TradeImport].each do |type|
      assert_no_difference -> { Import.count } do
        post imports_url, params: { import: { type: type, account_id: @linked.id } }
      end

      assert_redirected_to new_import_path
      assert_equal @message, flash[:alert]
    end
  end

  test "a new import into a manual account still works" do
    assert_difference -> { Import.count }, 1 do
      post imports_url, params: { import: { type: "TransactionImport", account_id: accounts(:credit_card).id } }
    end
  end

  test "a PDF import cannot be pointed at a linked account" do
    import = @user.family.imports.create!(type: "PdfImport")
    import.update_columns(status: "pending", ai_summary: "Summary", document_type: "bank_statement")

    patch import_url(import), params: { pdf_import: { account_id: @linked.id } }

    assert_redirected_to import_path(import)
    assert_equal @message, flash[:alert]
    assert_nil import.reload.account_id
  end

  test "an upload cannot switch the import to a linked account" do
    import = imports(:transaction)

    patch import_upload_url(import), params: { import: { raw_file_str: file_fixture("imports/valid.csv").read, col_sep: ",", account_id: @linked.id } }

    assert_redirected_to import_upload_path(import)
    assert_equal @message, flash[:alert]
    assert_nil import.reload.account_id
  end

  test "publishing an import mapped to a linked account shows the message" do
    import = imports(:transaction)
    import.mappings.create!(type: "Import::AccountMapping", key: @linked.name, mappable: @linked)

    post publish_import_url(import)

    assert_redirected_to import_path(import)
    assert_equal @message, flash[:alert]
    assert import.reload.pending?
  end

  test "the account menu offers no statement import for a linked account" do
    get account_path(@linked)
    assert_response :success
    assert_select "a[href*=?]", "TransactionImport", count: 0

    get account_path(accounts(:credit_card))
    assert_select "a[href*=?]", "TransactionImport"
  end
end
