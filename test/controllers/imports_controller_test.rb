require "test_helper"

class ImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "gets index" do
    get imports_url

    assert_response :success

    @user.family.imports.ordered.each do |import|
      assert_select "#" + dom_id(import), count: 1
    end
  end

  test "gets new" do
    get new_import_url

    assert_response :success

    assert_select "turbo-frame#modal"
  end

  test "the document upload on the new page submits through Turbo" do
    adapter = mock("vector_store_adapter")
    adapter.stubs(:supported_extensions).returns(%w[.pdf .txt])
    VectorStore.stubs(:adapter).returns(adapter)

    get new_import_url

    assert_response :success
    assert_select "form[data-turbo-frame=_top] input[type=file][onchange='this.form.requestSubmit()']", count: 1
    assert_select "input[type=file][onchange='this.form.submit()']", count: 0
    assert_includes response.body, I18n.t("imports.new.import_file")
  end

  test "create with an empty request body redirects back with an alert" do
    assert_no_difference "Import.count" do
      post imports_url
    end

    assert_redirected_to new_import_url
    assert_equal I18n.t("imports.create.missing_upload"), flash[:alert]
  end

  test "a DocumentImport without its file creates no import and redirects with an alert" do
    assert_no_difference "Import.count" do
      post imports_url, params: { import: { type: "DocumentImport" } }
    end

    assert_redirected_to new_import_url
    assert_equal I18n.t("imports.create.missing_upload"), flash[:alert]
  end

  test "creates import" do
    assert_difference "Import.count", 1 do
      post imports_url, params: {
        import: {
          type: "TransactionImport"
        }
      }
    end

    assert_redirected_to import_upload_url(Import.all.ordered.first)
  end

  test "publishes import" do
    import = imports(:transaction)

    TransactionImport.any_instance.expects(:publish_later).once

    post publish_import_url(import)

    assert_equal "Your import has started in the background.", flash[:notice]
    assert_redirected_to import_path(import)
  end

  test "destroys import" do
    import = imports(:transaction)

    assert_difference "Import.count", -1 do
      delete import_url(import)
    end

    assert_redirected_to imports_path
  end

  test "publishing twice shows an alert instead of starting a second import" do
    import = imports(:transaction)
    TransactionImport.any_instance.stubs(:publishable?).returns(true)

    post publish_import_url(import)
    assert import.reload.importing?

    assert_no_enqueued_jobs only: ImportJob do
      post publish_import_url(import)
    end

    assert_redirected_to import_path(import)
    assert_equal "This import can't be published in its current state.", flash[:alert]
  end

  test "a reverting import shows progress, not a publish button" do
    import = imports(:transaction)
    import.update_column(:status, "reverting")

    get import_url(import)

    assert_response :success
    assert_select "h1", text: "Reverting import"
    assert_select "form[action='#{publish_import_path(import)}']", count: 0
  end

  test "a failed revert offers a retry that uses the revert route's method" do
    import = imports(:transaction)
    import.update_column(:status, "revert_failed")

    get import_url(import)

    assert_select "form[action='#{revert_import_path(import)}'] input[name=_method][value=put]"
  end

  test "reverting an import that is not published shows an alert" do
    import = imports(:transaction)

    put revert_import_url(import)

    assert_redirected_to imports_path
    assert_equal "This import can't be reverted in its current state.", flash[:alert]
  end

  test "an import that is running or still published cannot be deleted" do
    import = imports(:transaction)

    %w[importing reverting complete].each do |state|
      import.update_column(:status, state)

      assert_no_difference "Import.count" do
        delete import_url(import)
      end

      assert_redirected_to imports_path
    end
  end

  test "deleting an import that still owns entries syncs the family" do
    import = imports(:transaction)
    import.update_column(:status, "reverted")
    accounts(:depository).entries.create!(date: Date.current, amount: 10, currency: "USD", name: "Left over", import: import, entryable: Transaction.new)

    Family.any_instance.expects(:sync_later).once

    assert_difference [ "Import.count", "Entry.count" ], -1 do
      delete import_url(import)
    end
  end

  test "an uploaded import that is not cleaned goes to the clean step, not into a redirect loop" do
    import = @user.family.imports.create!(type: "CategoryImport", raw_file_str: "name\nFood\n")

    get import_url(import)

    assert_redirected_to import_clean_path(import)
  end

  test "a published import cannot change its account" do
    import = imports(:transaction)
    import.update_column(:status, "complete")

    patch import_url(import), params: { import: { account_id: accounts(:depository).id } }

    assert_redirected_to import_path(import)
    assert_equal "This import can no longer be changed.", flash[:alert]
    assert_nil import.reload.account
  end

  test "choosing or changing a PDF import's account moves its rows to the account currency" do
    import = @user.family.imports.create!(type: "PdfImport")
    import.update_columns(status: "pending", ai_summary: "Summary", document_type: "bank_statement")
    import.rows.create!(date: "01/01/2024", amount: "-10", name: "Coffee", currency: "UAH")
    eur_account = accounts(:credit_card)
    eur_account.update_column(:currency, "EUR")

    patch import_url(import), params: { pdf_import: { account_id: accounts(:depository).id } }

    assert_redirected_to import_path(import)
    assert_equal "Account saved.", flash[:notice]
    assert_equal [ "USD" ], import.rows.pluck(:currency)

    patch import_url(import), params: { pdf_import: { account_id: eur_account.id } }

    assert_equal eur_account, import.reload.account
    assert_equal [ "EUR" ], import.rows.pluck(:currency)
  end

  test "a PDF import under review lists rows the account already records" do
    account = accounts(:depository)
    existing = account.entries.create!(date: Date.new(2024, 1, 2), amount: 10, currency: "USD", name: "Coffee by hand", entryable: Transaction.new)
    import = @user.family.imports.create!(type: "PdfImport", account: account)
    import.update_columns(status: "pending", ai_summary: "Summary", document_type: "bank_statement")
    import.rows.create!(date: "01/01/2024", amount: "-10", name: "CARD COFFEE", currency: "USD")
    import.rows.create!(date: "01/01/2024", amount: "-25", name: "BAKERY", currency: "USD")
    import.update_column(:rows_count, 2)

    get import_url(import)

    assert_response :success
    assert_select "#already_recorded a[href='#{entry_path(existing)}']"
    assert_select "form[action='#{publish_import_path(import)}']"
    assert_includes response.body, "Publish 1 new transaction"
    assert_includes response.body, "1 transaction already recorded"
  end

  test "a CSV import ready to publish counts only new rows and lists the entries it takes over" do
    account = accounts(:depository)
    same_name = account.entries.create!(date: Date.new(2024, 1, 1), amount: 100, currency: "USD", name: "Coffee Shop", entryable: Transaction.new)
    nearby = account.entries.create!(date: Date.new(2024, 1, 2), amount: 40, currency: "USD", name: "Typed by hand", entryable: Transaction.new)

    import = @user.family.imports.create!(
      type: "TransactionImport",
      account: account,
      raw_file_str: "date,name,amount\n01/01/2024,Coffee Shop,100\n01/01/2024,CARD BAKERY,40\n01/03/2024,Books,25\n",
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      date_format: "%m/%d/%Y",
      amount_type_strategy: "signed_amount",
      signage_convention: "inflows_negative"
    )
    import.generate_rows_from_csv
    import.reload.sync_mappings

    get import_url(import)

    assert_response :success
    assert_select "#already_recorded a[href='#{entry_path(nearby)}']"
    assert_select "#already_claimed a[href='#{entry_path(same_name)}']"
    assert_includes response.body, "1 transaction already recorded under the same name"
    # Only the Books row creates an entry
    assert_equal({ transactions: 1, categories: 0, tags: 0 }, import.dry_run)
  end

  test "a processing PDF offers a way out" do
    import = @user.family.imports.create!(type: "PdfImport")
    import.update_column(:status, "processing")

    get import_url(import)

    assert_response :success
    assert_select "form[action='#{import_path(import)}'] input[name='_method'][value='delete']"
  end

  test "a processing PDF import polls the page and keeps a refresh link" do
    import = @user.family.imports.create!(type: "PdfImport")
    import.update_column(:status, "processing")

    get import_url(import)

    assert_response :success
    assert_select "turbo-frame##{dom_id(import, :pdf_import)}[target='_top'][data-controller='polling'][data-polling-url-value='#{import_path(import)}']"
    assert_select "turbo-frame##{dom_id(import, :pdf_import)} a[href='#{import_path(import)}']", text: "Refresh status"
  end

  test "a PDF import that is not processing does not poll" do
    import = @user.family.imports.create!(type: "PdfImport", account: accounts(:depository))

    %w[pending processing_failed indexed complete].each do |status|
      import.update_columns(status: status, ai_summary: "Summary", document_type: "bank_statement")

      get import_url(import)

      assert_response :success
      assert_select "turbo-frame##{dom_id(import, :pdf_import)}", count: 1
      assert_select "turbo-frame##{dom_id(import, :pdf_import)}[data-polling-url-value]", count: 0, message: "#{status} should not poll"
    end
  end

  test "a PDF whose processing failed can be retried" do
    import = @user.family.imports.create!(type: "PdfImport")
    import.pdf_file.attach(io: StringIO.new("%PDF-1.4 test"), filename: "statement.pdf", content_type: "application/pdf")
    import.update_column(:status, "processing_failed")

    get import_url(import)
    assert_select "form[action='#{retry_processing_import_path(import)}']"

    assert_enqueued_with(job: ProcessPdfJob) do
      post retry_processing_import_url(import)
    end

    assert import.reload.processing?
    assert_redirected_to import_path(import)
  end
end
