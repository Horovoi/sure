class VectorStore::Base
  SUPPORTED_EXTENSIONS = %w[
    .c .cpp .css .csv .docx .gif .go .html .java .jpeg .jpg .js .json
    .md .pdf .php .png .pptx .py .rb .sh .tar .tex .ts .txt .xlsx .xml .zip
  ].freeze

  def create_store(name:)
    raise NotImplementedError
  end

  def delete_store(store_id:)
    raise NotImplementedError
  end

  def upload_file(store_id:, file_content:, filename:)
    raise NotImplementedError
  end

  def remove_file(store_id:, file_id:)
    raise NotImplementedError
  end

  def search(store_id:, query:, max_results: 10)
    raise NotImplementedError
  end

  def supported_extensions
    SUPPORTED_EXTENSIONS
  end

  private
    def success(data)
      VectorStore::Response.new(success?: true, data: data, error: nil)
    end

    def failure(error)
      wrapped_error = error.is_a?(VectorStore::Error) ? error : VectorStore::Error.new(error.message)
      VectorStore::Response.new(success?: false, data: nil, error: wrapped_error)
    end

    def with_response(&block)
      success(yield)
    rescue => error
      Rails.logger.error("#{self.class.name} error: #{error.class} - #{error.message}")
      failure(error)
    end
end
