require "test_helper"

class Family::VectorSearchableTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update_column(:vector_store_id, nil)
    @adapter = mock("vector_store_adapter")
    Family.any_instance.stubs(:vector_store_adapter).returns(@adapter)
  end

  test "uploads a document as pending, then marks it ready with the provider file id" do
    @family.update_column(:vector_store_id, "vs_1")
    @adapter.expects(:upload_file).with do |store_id:, file_content:, filename:|
      # The row and its local copy exist before the remote upload
      document = @family.family_documents.find_by!(filename: "notes.txt")
      assert document.processing?
      assert document.file.attached?
      store_id == "vs_1" && file_content == "hello" && filename == "notes.txt"
    end.returns(ok_response(file_id: "file_1"))

    document = @family.upload_document(file_content: "hello", filename: "notes.txt")

    assert document.ready?
    assert_equal "file_1", document.provider_file_id
  end

  test "a failed upload leaves an error row" do
    @family.update_column(:vector_store_id, "vs_1")
    @adapter.expects(:upload_file).returns(failed_response("upload rejected"))

    assert_nil @family.upload_document(file_content: "hello", filename: "notes.txt")

    document = @family.family_documents.find_by!(filename: "notes.txt")
    assert document.error?
    assert_equal "upload rejected", document.metadata["error"]
  end

  test "a document for an import is uploaded once" do
    @family.update_column(:vector_store_id, "vs_1")
    @adapter.expects(:upload_file).once.returns(ok_response(file_id: "file_1"))

    first = @family.upload_document(file_content: "pdf", filename: "statement.pdf", metadata: { "import_id" => "imp_1" })
    second = @family.upload_document(file_content: "pdf", filename: "statement.pdf", metadata: { "import_id" => "imp_1" })

    assert_equal first, second
  end

  test "keeps the store another caller created first and deletes its own" do
    @adapter.expects(:create_store).returns(ok_response(id: "vs_mine"))
    @adapter.expects(:delete_store).with(store_id: "vs_mine")

    # Another process set the store between our check and our write
    stale_copy = Family.find(@family.id)
    @family.update_column(:vector_store_id, "vs_theirs")

    assert_equal "vs_theirs", stale_copy.ensure_vector_store!
    assert_equal "vs_theirs", @family.reload.vector_store_id
  end

  test "creates the store once" do
    @adapter.expects(:create_store).once.returns(ok_response(id: "vs_new"))
    @adapter.expects(:delete_store).never

    assert_equal "vs_new", @family.ensure_vector_store!
    assert_equal "vs_new", @family.ensure_vector_store!
    assert_equal "vs_new", @family.reload.vector_store_id
  end

  private
    def ok_response(data)
      VectorStore::Response.new(success?: true, data: data, error: nil)
    end

    def failed_response(message)
      VectorStore::Response.new(success?: false, data: nil, error: VectorStore::Error.new(message))
    end
end
