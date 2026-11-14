class ProcessPdfJob < ApplicationJob
  queue_as :medium_priority

  # Runs the AI steps for a PdfImport in the processing state. Each step skips work a
  # previous attempt already finished (AI summary, vault upload, extraction), so a retry
  # after a failure does not repeat paid calls or upload the document twice.
  # Failures end in processing_failed, which the user can retry; the job is not retried.
  def perform(pdf_import)
    return unless pdf_import.is_a?(PdfImport)

    unless pdf_import.processing?
      Rails.logger.warn("ProcessPdfJob: import #{pdf_import.id} is #{pdf_import.status}, not processing. Skipping.")
      return
    end

    process(pdf_import)
  rescue ActiveRecord::RecordNotFound
    Rails.logger.info("ProcessPdfJob: import #{pdf_import.id} was deleted while processing")
  end

  private
    def process(pdf_import)
      raise "PDF file is missing" unless pdf_import.pdf_uploaded?

      pdf_import.process_with_ai unless pdf_import.ai_processed?
      upload_to_vector_store(pdf_import)

      if pdf_import.statement_with_transactions?
        pdf_import.extract_transactions unless pdf_import.has_extracted_transactions?
        pdf_import.generate_rows_from_extracted_data
        pdf_import.sync_mappings
      end

      if pdf_import.statement_with_transactions? && pdf_import.rows_count > 0
        pdf_import.mark_ready!
      else
        pdf_import.mark_indexed!
      end
    rescue ActiveRecord::RecordNotFound
      raise
    rescue StandardError => error
      sanitized_error = sanitize_error_message(error)
      Rails.logger.error("PDF processing failed for import #{pdf_import.id}: #{error.class.name} - #{sanitized_error}")

      begin
        pdf_import.fail_processing!(sanitized_error)
      rescue AASM::InvalidTransition => transition_error
        Rails.logger.error("Failed to update import status for #{pdf_import.id}: #{transition_error.message}")
      end
    end

    def sanitize_error_message(error)
      case error
      when RuntimeError, ArgumentError
        error.message.truncate(500)
      else
        "PDF processing failed (#{error.class.name.demodulize})"
      end
    end

    def upload_to_vector_store(pdf_import)
      return unless VectorStore.configured?
      return if already_uploaded?(pdf_import)

      filename = pdf_import.pdf_file.filename.to_s
      file_content = pdf_import.pdf_file_content

      family_document = pdf_import.family.upload_document(
        file_content: file_content,
        filename: filename,
        metadata: { "type" => pdf_import.document_type, "import_id" => pdf_import.id }
      )

      Rails.logger.warn("ProcessPdfJob: Vector store upload failed for import #{pdf_import.id}") unless family_document
    end

    def already_uploaded?(pdf_import)
      pdf_import.family.family_documents.where("metadata->>'import_id' = ?", pdf_import.id.to_s).exists?
    end
end
