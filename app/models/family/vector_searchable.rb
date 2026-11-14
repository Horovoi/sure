module Family::VectorSearchable
  extend ActiveSupport::Concern

  included do
    has_many :family_documents, dependent: :destroy
  end

  # Creates the family's vector store once. Two callers racing (ProcessPdfJob and a document upload) may both
  # create a store; only the first to claim the empty column keeps its store, the other deletes its own.
  def ensure_vector_store!
    return vector_store_id if vector_store_id.present?

    adapter = vector_store_adapter
    return nil unless adapter

    response = adapter.create_store(name: "Family #{id} Documents")
    return nil unless response.success?

    new_store_id = response.data[:id]
    claimed = self.class.where(id: id, vector_store_id: nil).update_all(vector_store_id: new_store_id) == 1

    unless claimed
      adapter.delete_store(store_id: new_store_id) rescue nil
    end

    self[:vector_store_id] = self.class.where(id: id).pick(:vector_store_id)
    clear_attribute_changes([ :vector_store_id ])
    vector_store_id
  end

  def search_documents(query, max_results: 10)
    return [] unless vector_store_id.present?

    adapter = vector_store_adapter
    return [] unless adapter

    response = adapter.search(
      store_id: vector_store_id,
      query: query,
      max_results: max_results
    )

    response.success? ? response.data : []
  end

  # Saves the document (pending) with its local copy first, then uploads it, so a failed upload leaves an
  # error row instead of an orphaned remote file. Returns the ready document, or nil when the upload failed.
  # A document for an import is uploaded once: a retried ProcessPdfJob gets the existing ready document.
  def upload_document(file_content:, filename:, metadata: {})
    adapter = vector_store_adapter
    return nil unless adapter

    metadata = (metadata || {}).stringify_keys
    if metadata["import_id"].present?
      existing = family_documents.ready.find_by("metadata->>'import_id' = ?", metadata["import_id"].to_s)
      return existing if existing
    end

    store_id = ensure_vector_store!
    return nil unless store_id

    family_document = family_documents.create!(
      filename: filename,
      content_type: Marcel::MimeType.for(name: filename),
      file_size: file_content.bytesize,
      metadata: metadata
    )

    family_document.file.attach(
      io: StringIO.new(file_content),
      filename: filename,
      content_type: family_document.content_type
    )

    family_document.start_upload!

    response = adapter.upload_file(
      store_id: store_id,
      file_content: file_content,
      filename: filename
    )

    unless response.success?
      family_document.mark_error!(response.error&.message)
      return nil
    end

    begin
      family_document.mark_ready!(response.data[:file_id])
    rescue
      # Do not leave a remote file that no row points to
      adapter.remove_file(store_id: store_id, file_id: response.data[:file_id])
      raise
    end

    family_document
  end

  def remove_document(family_document)
    adapter = vector_store_adapter
    return false unless adapter && vector_store_id.present? && family_document.provider_file_id.present?

    response = adapter.remove_file(
      store_id: vector_store_id,
      file_id: family_document.provider_file_id
    )

    return false unless response.success?

    family_document.destroy
    true
  end

  private
    def vector_store_adapter
      VectorStore.adapter
    end
end
