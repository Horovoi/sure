class Assistant::Function::SearchFamilyFiles < Assistant::Function
  class << self
    def name
      "search_family_files"
    end

    def description
      <<~DESC
        Search the family's uploaded documents and return the most relevant excerpts.

        Use this when the user asks about uploaded PDFs, statements, tax documents,
        contracts, reports, notes, or any other file stored in the family vault.
      DESC
    end
  end

  def strict_mode?
    false
  end

  # Read-only, but the search runs in the vector store provider, outside Sure
  def open_world?
    true
  end

  def params_schema
    build_schema(
      required: [ "query" ],
      properties: {
        query: {
          type: "string",
          description: "Natural-language search query for the family's uploaded documents"
        },
        max_results: {
          type: "integer",
          description: "Maximum number of results to return (default 10, max 20)"
        }
      }
    )
  end

  def call(params = {})
    query = params["query"].to_s
    max_results = (params["max_results"] || 10).to_i.clamp(1, 20)

    unless VectorStore.configured?
      return {
        success: false,
        error: "provider_not_configured",
        message: "Document search is not configured. Configure OpenAI/vector-store support first."
      }
    end

    unless family.vector_store_id.present?
      return {
        success: false,
        error: "no_documents",
        message: "No documents have been uploaded to the family document vault yet."
      }
    end

    response = VectorStore.adapter.search(
      store_id: family.vector_store_id,
      query: query,
      max_results: max_results
    )

    unless response.success?
      # The provider's message can carry request internals, so it stays in the log (decision 15)
      Rails.logger.error("SearchFamilyFiles provider error: #{response.error&.class&.name} - #{response.error&.message}")
      return {
        success: false,
        error: "search_failed",
        message: "Failed to search documents. Try again later."
      }
    end

    results = response.data
    return { success: true, results: [], message: "No matching documents found." } if results.empty?

    {
      success: true,
      query: query,
      result_count: results.size,
      results: results.map do |result|
        {
          content: result[:content],
          filename: result[:filename],
          score: result[:score]
        }
      end
    }
  rescue => error
    Rails.logger.error("SearchFamilyFiles error: #{error.class.name} - #{error.message}")
    {
      success: false,
      error: "search_failed",
      message: "An error occurred while searching documents. Try again later."
    }
  end
end
