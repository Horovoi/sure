require "test_helper"

class VectorStore::OpenaiTest < ActiveSupport::TestCase
  setup do
    @store = VectorStore::Openai.new(access_token: "test-token")
    @client = @store.send(:client)
  end

  test "remove_file detaches the file and deletes it" do
    vector_store_files = mock("vector_store_files")
    files = mock("files")
    @client.stubs(:vector_store_files).returns(vector_store_files)
    @client.stubs(:files).returns(files)

    vector_store_files.expects(:delete).with(vector_store_id: "vs_1", id: "file_1")
    files.expects(:delete).with(id: "file_1")

    assert @store.remove_file(store_id: "vs_1", file_id: "file_1").success?
  end

  test "remove_file deletes a file that is no longer in the store" do
    vector_store_files = mock("vector_store_files")
    files = mock("files")
    @client.stubs(:vector_store_files).returns(vector_store_files)
    @client.stubs(:files).returns(files)

    vector_store_files.expects(:delete).raises(Faraday::ResourceNotFound.new("not found"))
    files.expects(:delete).with(id: "file_1")

    assert @store.remove_file(store_id: "vs_1", file_id: "file_1").success?
  end
end
