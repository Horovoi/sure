class PdfImport < Import
  has_one_attached :pdf_file, dependent: :purge_later

  validates :document_type, inclusion: { in: DOCUMENT_TYPES }, allow_nil: true

  # Rows the account already records are skipped and the matched entries are left
  # untouched (decision 27), so revert removes only what this import created.
  def import!
    raise "Account required for PDF import" unless account.present?

    transaction do
      # Built again here, inside the publish lock, so an entry added between review
      # and publish is caught too.
      matcher = duplicate_matcher
      new_rows = rows.ordered.reject { |row| matcher.matched?(row) }

      category_keys = new_rows.map(&:category).to_set
      mappings.each { |mapping| mapping.create_mappable! if category_keys.include?(mapping.key) }

      new_transactions = new_rows.map do |row|
        category = mappings.categories.mappable_for(row.category)

        Transaction.new(
          category: category,
          entry: Entry.new(
            account: account,
            date: row.date_iso,
            amount: row.signed_amount,
            name: row.name,
            currency: row_currency(row, account),
            notes: row.notes,
            import: self,
            import_locked: true
          )
        )
      end

      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
    end
  end

  # Rows are extracted before an account is chosen, so their own currency is only a guess
  def row_currency(_row, account)
    account.currency
  end

  # { row id => Entry } for the rows the chosen account already records. Empty until
  # an account is chosen. On a finished import only entries that existed at publish
  # time count, so the list shows what publishing skipped.
  def already_recorded
    return {} if account.blank?

    @already_recorded ||= duplicate_matcher(created_before: complete? ? published_at : nil).matches
  end

  def new_rows_count
    rows_count - already_recorded.size
  end

  def pdf_uploaded?
    pdf_file.attached?
  end

  def ai_processed?
    ai_summary.present?
  end

  # Starts (or retries) AI processing. Raises AASM::InvalidTransition unless the
  # import is new or its processing failed.
  def process_with_ai_later
    start_processing!
    ProcessPdfJob.perform_later(self)
  end

  def process_with_ai
    provider = Provider::Registry.get_provider(:openai)
    raise "AI provider not configured" unless provider
    raise "AI provider does not support PDF processing" unless provider.supports_pdf_processing?

    response = provider.process_pdf(
      pdf_content: pdf_file_content,
      family: family
    )

    unless response.success?
      error_message = response.error&.message || "Unknown PDF processing error"
      raise error_message
    end

    result = response.data
    update!(
      ai_summary: result.summary,
      document_type: result.document_type
    )

    result
  end

  def extract_transactions
    return unless statement_with_transactions?

    provider = Provider::Registry.get_provider(:openai)
    raise "AI provider not configured" unless provider

    response = provider.extract_bank_statement(
      pdf_content: pdf_file_content,
      family: family
    )

    unless response.success?
      error_message = response.error&.message || "Unknown extraction error"
      raise error_message
    end

    extracted_payload = response.data.respond_to?(:to_h) ? response.data.to_h : response.data
    # The extractor returns symbol keys, but every reader digs with strings, and jsonb
    # keeps the assigned hash until reload (ProcessPdfJob never reloads)
    extracted_payload = extracted_payload.deep_stringify_keys if extracted_payload.is_a?(Hash)
    update!(extracted_data: extracted_payload)
    extracted_payload
  end

  def bank_statement?
    document_type == "bank_statement"
  end

  def statement_with_transactions?
    document_type.in?(%w[bank_statement credit_card_statement])
  end

  def has_extracted_transactions?
    extracted_data.present? && extracted_data["transactions"].present?
  end

  def extracted_transactions
    extracted_data&.dig("transactions") || []
  end

  def generate_rows_from_extracted_data
    transaction do
      # insert_all! below bypasses the association, so a loaded rows cache can be stale
      rows.reload.destroy_all

      unless has_extracted_transactions?
        refresh_rows_count!
        return
      end

      currency = account&.currency || family.currency

      mapped_rows = extracted_transactions.map do |txn|
        {
          import_id: id,
          date: format_date_for_import(txn["date"]),
          amount: txn["amount"].to_s,
          name: txn["name"].to_s,
          category: txn["category"].to_s,
          notes: txn["notes"].to_s,
          currency: currency
        }
      end

      Import::Row.insert_all!(mapped_rows) if mapped_rows.any?
      rows.reset
      @already_recorded = nil
      refresh_rows_count!
    end
  end

  def uploaded?
    pdf_uploaded?
  end

  def configured?
    ai_processed? && (!statement_with_transactions? || rows_count > 0)
  end

  def cleaned?
    configured? && (rows_count.zero? || rows.all?(&:valid?))
  end

  def publishable?
    account.present? && statement_with_transactions? && cleaned? && mappings_valid?
  end

  def column_keys
    %i[date amount name category notes]
  end

  def requires_csv_workflow?
    false
  end

  def pdf_file_content
    return nil unless pdf_file.attached?

    pdf_file.download
  end

  def required_column_keys
    %i[date amount]
  end

  def mapping_steps
    steps = []
    steps << Import::CategoryMapping if rows.where.not(category: [ nil, "" ]).exists?
    steps
  end

  private
    def duplicate_matcher(created_before: nil)
      Import::DuplicateMatcher.new(import: self, account: account, rows: rows.ordered.to_a, created_before: created_before)
    end

    # Entries are written in one insert when the import publishes. With none
    # (everything was already recorded) the state change is the last write.
    def published_at
      entries.minimum(:created_at) || updated_at
    end

    def awaiting_processing?
      !ai_processed?
    end

    def format_date_for_import(date_str)
      return "" if date_str.blank?

      Date.parse(date_str).strftime(date_format)
    rescue ArgumentError
      date_str.to_s
    end
end
