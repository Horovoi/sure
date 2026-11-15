require "test_helper"

class ProcessPdfJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @import = @family.imports.create!(type: "PdfImport", date_format: "%m/%d/%Y")
    @import.pdf_file.attach(io: StringIO.new("%PDF-1.4 test"), filename: "statement.pdf", content_type: "application/pdf")
  end

  test "a new PDF moves to processing and then to review with extracted rows" do
    assert_enqueued_with(job: ProcessPdfJob) { @import.process_with_ai_later }
    assert @import.reload.processing?

    stub_ai(@import, document_type: "bank_statement")
    stub_extraction(@import)

    ProcessPdfJob.perform_now(@import)

    assert @import.reload.pending?
    assert_equal 1, @import.rows_count
    assert @import.editable?
  end

  test "a document without transactions ends indexed and cannot be reverted" do
    @import.process_with_ai_later
    stub_ai(@import, document_type: "contract")

    ProcessPdfJob.perform_now(@import)

    assert @import.reload.indexed?
    assert_not @import.revertable?
    assert @import.deletable?
  end

  test "a failure ends in processing_failed without raising, and a retry skips finished AI steps" do
    @import.process_with_ai_later
    stub_ai(@import, document_type: "bank_statement")
    @import.stubs(:extract_transactions).raises(StandardError, "provider timeout")

    assert_nothing_raised { ProcessPdfJob.perform_now(@import) }

    assert @import.reload.processing_failed?
    assert_match(/StandardError/, @import.error)

    @import.process_with_ai_later
    assert @import.reload.processing?
    assert_nil @import.error

    retried = PdfImport.find(@import.id)
    retried.expects(:process_with_ai).never
    stub_extraction(retried)

    ProcessPdfJob.perform_now(retried)

    assert retried.reload.pending?
  end

  test "a job for an import that is not processing does nothing" do
    @import.expects(:process_with_ai).never

    ProcessPdfJob.perform_now(@import)

    assert @import.reload.pending?
  end

  test "the document is uploaded to the vault only once" do
    VectorStore.stubs(:configured?).returns(true)
    @family.family_documents.create!(filename: "statement.pdf", status: "ready", metadata: { "import_id" => @import.id })
    @import.process_with_ai_later
    stub_ai(@import, document_type: "contract")
    adapter = mock("vector_store_adapter")
    adapter.expects(:upload_file).never
    Family.any_instance.stubs(:vector_store_adapter).returns(adapter)

    ProcessPdfJob.perform_now(@import)

    assert @import.reload.indexed?
  end

  test "a failed vault upload is tried again on the next run" do
    VectorStore.stubs(:configured?).returns(true)
    @family.update_column(:vector_store_id, "vs_1")
    @family.family_documents.create!(filename: "statement.pdf", status: "error", metadata: { "import_id" => @import.id })
    @import.process_with_ai_later
    stub_ai(@import, document_type: "contract")
    adapter = mock("vector_store_adapter")
    adapter.expects(:upload_file).once.returns(VectorStore::Response.new(success?: true, data: { file_id: "file_1" }, error: nil))
    Family.any_instance.stubs(:vector_store_adapter).returns(adapter)

    ProcessPdfJob.perform_now(@import)

    assert @import.reload.indexed?
    assert @family.family_documents.ready.exists?(provider_file_id: "file_1")
  end

  test "a reviewed PDF can not be processed again" do
    @import.update_columns(status: "pending", ai_summary: "done", document_type: "bank_statement")

    assert_raises(AASM::InvalidTransition) { @import.process_with_ai_later }
  end

  test "published entries use the chosen account's currency" do
    account = accounts(:depository)
    account.update_column(:currency, "EUR")
    @import.update_columns(status: "pending", ai_summary: "done", document_type: "bank_statement")
    @import.rows.create!(date: "01/01/2024", amount: "10", name: "Coffee", currency: "USD")
    @import.update!(account: account)

    @import.publish

    assert @import.reload.complete?
    assert_equal [ "EUR" ], @import.entries.pluck(:currency)
  end

  test "runs in the AI lane's low-priority queue" do
    assert_equal "ai_low_priority", ProcessPdfJob.queue_name
  end

  private
    def stub_ai(import, document_type:)
      import.define_singleton_method(:process_with_ai) do
        update!(ai_summary: "Summary", document_type: document_type)
      end
    end

    def stub_extraction(import)
      import.define_singleton_method(:extract_transactions) do
        update!(extracted_data: { "transactions" => [ { "date" => "2024-01-01", "amount" => "10", "name" => "Coffee" } ] })
      end
    end
end
