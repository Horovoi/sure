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

  test "a processing PDF offers a way out" do
    import = @user.family.imports.create!(type: "PdfImport")
    import.update_column(:status, "processing")

    get import_url(import)

    assert_response :success
    assert_select "form[action='#{import_path(import)}'] input[name='_method'][value='delete']"
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
