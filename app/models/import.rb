class Import < ApplicationRecord
  include AASM

  MaxRowCountExceededError = Class.new(StandardError)
  MappingError = Class.new(StandardError)
  NotPublishableError = Class.new(RuntimeError)
  NotRevertableError = Class.new(RuntimeError)

  MAX_CSV_SIZE = 10.megabytes
  MAX_PDF_SIZE = 25.megabytes
  ALLOWED_CSV_MIME_TYPES = %w[text/csv text/plain application/vnd.ms-excel application/csv].freeze
  ALLOWED_PDF_MIME_TYPES = %w[application/pdf].freeze
  ALLOWED_MIME_TYPES = ALLOWED_CSV_MIME_TYPES
  DOCUMENT_TYPES = %w[
    bank_statement
    credit_card_statement
    investment_statement
    financial_document
    contract
    other
  ].freeze

  TYPES = %w[TransactionImport TradeImport AccountImport MintImport CategoryImport RuleImport PdfImport].freeze
  SIGNAGE_CONVENTIONS = %w[inflows_positive inflows_negative]
  SEPARATORS = [ [ "Comma (,)", "," ], [ "Semicolon (;)", ";" ] ].freeze

  NUMBER_FORMATS = {
    "1,234.56" => { separator: ".", delimiter: "," },  # US/UK/Asia
    "1.234,56" => { separator: ",", delimiter: "." },  # Most of Europe
    "1 234,56" => { separator: ",", delimiter: " " },  # French/Scandinavian
    "1,234"    => { separator: "",  delimiter: "," }   # Zero-decimal currencies like JPY
  }.freeze

  AMOUNT_TYPE_STRATEGIES = %w[signed_amount custom_column].freeze

  belongs_to :family
  belongs_to :account, optional: true

  before_validation :set_default_number_format
  before_validation :ensure_utf8_encoding

  scope :ordered, -> { order(created_at: :desc) }

  # How long an import may sit in an in-progress state before the stale work reaper
  # moves it to its failure state with #mark_stale!.
  STALE_AFTER = 15.minutes
  IN_PROGRESS_STATES = %w[processing importing reverting].freeze

  # pending           - being configured (CSV wizard), or a PDF ready for review
  # processing        - PdfImport only: AI is reading the document
  # processing_failed - PdfImport only: AI processing failed; can be retried
  # indexed           - PdfImport only: stored in the document vault, nothing to publish
  # importing         - ImportJob is writing entries
  # complete          - published
  # failed            - publishing failed and was rolled back; can be edited and retried
  # reverting         - RevertImportJob is removing the published data
  # reverted          - published data removed; can be edited and published again
  # revert_failed     - reverting failed and was rolled back; can be retried
  aasm column: :status, requires_lock: true, whiny_persistence: true do
    state :pending, initial: true
    state :processing
    state :processing_failed
    state :indexed
    state :importing
    state :complete
    state :failed
    state :reverting
    state :reverted
    state :revert_failed

    event :start_processing, before: :clear_error do
      transitions from: :pending, to: :processing, guard: :awaiting_processing?
      transitions from: :processing_failed, to: :processing
    end

    event :mark_ready do
      transitions from: :processing, to: :pending
    end

    event :mark_indexed do
      transitions from: :processing, to: :indexed
    end

    event :fail_processing, before: :assign_error do
      transitions from: :processing, to: :processing_failed
    end

    event :start_import, before: :clear_error do
      transitions from: %i[pending failed reverted], to: :importing
    end

    event :complete_import do
      transitions from: :importing, to: :complete
    end

    event :fail_import, before: :assign_error do
      transitions from: :importing, to: :failed
    end

    event :start_revert, before: :clear_error do
      transitions from: %i[complete revert_failed], to: :reverting, guard: :supports_revert?
    end

    event :finish_revert do
      transitions from: :reverting, to: :reverted
    end

    event :fail_revert, before: :assign_error do
      transitions from: :reverting, to: :revert_failed
    end

    # Terminal failure for work whose job never finished (worker killed, enqueue lost).
    # Called by the stale work reaper.
    event :mark_stale, before: :assign_stale_error do
      transitions from: :processing, to: :processing_failed
      transitions from: :importing, to: :failed
      transitions from: :reverting, to: :revert_failed
    end
  end

  scope :in_progress, -> { where(status: IN_PROGRESS_STATES) }
  scope :stale, -> { in_progress.where(updated_at: ...STALE_AFTER.ago) }

  validates :type, inclusion: { in: TYPES }
  validates :amount_type_strategy, inclusion: { in: AMOUNT_TYPE_STRATEGIES }
  validates :col_sep, inclusion: { in: SEPARATORS.map(&:last) }
  validates :signage_convention, inclusion: { in: SIGNAGE_CONVENTIONS }, allow_nil: true
  validates :number_format, presence: true, inclusion: { in: NUMBER_FORMATS.keys }
  validates :rows_to_skip, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :account_belongs_to_family
  validate :rows_to_skip_within_file_bounds

  has_many :rows, dependent: :destroy
  has_many :mappings, dependent: :destroy
  has_many :accounts, dependent: :destroy
  has_many :entries, dependent: :destroy
  has_many :claimed_entries, class_name: "Import::ClaimedEntry", dependent: :delete_all

  # Hand claimed entries back before the dependent destroys above remove them.
  before_destroy :release_claimed_entries!, prepend: true

  class << self
    def parse_csv_str(csv_str, col_sep: ",")
      CSV.parse(
        (csv_str || "").strip,
        headers: true,
        col_sep: col_sep,
        converters: [ ->(str) { str&.strip } ],
        liberal_parsing: true
      )
    end
  end

  def publish_later
    raise MaxRowCountExceededError if row_count_exceeded?
    raise NotPublishableError, "Import is not publishable" unless publishable?

    start_import!

    ImportJob.perform_later(self)
  end

  # Publishes synchronously. A pending, failed or reverted import is started first;
  # an import in any other state is left alone. Entries and the complete state are
  # written in one transaction, so a failure leaves nothing behind.
  def publish
    start_import! if may_start_import?

    with_lock do
      unless importing?
        Rails.logger.warn("Import #{id} is #{status}, not importing. Skipping publish.")
        return
      end

      raise MaxRowCountExceededError if row_count_exceeded?

      import!
      complete_import!
    end

    family.sync_later
  rescue => error
    record_failure(:fail_import, error)
  end

  def revert_later
    raise NotRevertableError, "Import is not revertable" unless revertable?

    start_revert!

    RevertImportJob.perform_later(self)
  end

  def revert
    with_lock do
      unless reverting?
        Rails.logger.warn("Import #{id} is #{status}, not reverting. Skipping revert.")
        return
      end

      release_claimed_entries!
      remove_created_accounts!
      entries.destroy_all
      finish_revert!
    end

    family.sync_later
  rescue => error
    record_failure(:fail_revert, error)
  end

  def in_progress?
    status.in?(IN_PROGRESS_STATES)
  end

  # Configuration, rows and mappings can change only while nothing is published.
  def editable?
    pending? || failed? || reverted?
  end

  def revertable?
    may_start_revert?
  end

  # A published import must be reverted first, so deleting never drops its data
  # without the revert bookkeeping. In-progress imports wait for their job (or the reaper).
  def deletable?
    !(importing? || reverting?) && !revertable?
  end

  # Records a pre-existing entry this import takes over, with the values it is about
  # to overwrite. Call before changing the entry.
  def claim_entry!(entry)
    claimed_entries.find_or_create_by!(entry: entry) do |claim|
      claim.previous_import_id = entry.import_id
      claim.previous_category_id = entry.transaction&.category_id
      claim.previous_tag_ids = entry.transaction&.tag_ids || []
      claim.previous_notes = entry.notes
      claim.previous_import_locked = entry.import_locked
    end
  end

  def csv_rows
    @csv_rows ||= parsed_csv
  end

  def csv_headers
    parsed_csv.headers
  end

  def csv_sample
    @csv_sample ||= parsed_csv.first(2)
  end

  def dry_run
    mappings = {
      transactions: rows_count,
      categories: Import::CategoryMapping.for_import(self).creational.count,
      tags: Import::TagMapping.for_import(self).creational.count
    }

    mappings.merge(
      accounts: Import::AccountMapping.for_import(self).creational.count,
    ) if account.nil?

    mappings
  end

  def required_column_keys
    []
  end

  def column_keys
    raise NotImplementedError, "Subclass must implement column_keys"
  end

  def generate_rows_from_csv
    rows.destroy_all

    mapped_rows = csv_rows.map do |row|
      {
        account: row[account_col_label].to_s,
        date: row[date_col_label].to_s,
        qty: sanitize_number(row[qty_col_label]).to_s,
        ticker: row[ticker_col_label].to_s,
        exchange_operating_mic: row[exchange_operating_mic_col_label].to_s,
        price: sanitize_number(row[price_col_label]).to_s,
        amount: sanitize_number(row[amount_col_label]).to_s,
        currency: (row[currency_col_label] || default_currency).to_s,
        name: (row[name_col_label] || default_row_name).to_s,
        category: row[category_col_label].to_s,
        tags: row[tags_col_label].to_s,
        entity_type: row[entity_type_col_label].to_s,
        notes: row[notes_col_label].to_s
      }
    end

    rows.insert_all!(mapped_rows)
    refresh_rows_count!
  end

  def sync_mappings
    transaction do
      mapping_steps.each do |mapping_class|
        mappables_by_key = mapping_class.mappables_by_key(self)

        updated_mappings = mappables_by_key.map do |key, mappable|
          mapping = mappings.find_or_initialize_by(key: key, import: self, type: mapping_class.name)
          mapping.mappable = mappable
          mapping.create_when_empty = key.present? && mappable.nil?
          mapping
        end

        updated_mappings.each { |m| m.save(validate: false) }
        mappings.where(type: mapping_class.name).where.not(id: updated_mappings.map(&:id)).destroy_all
      end

      # Mapping types that no longer apply (e.g. account mappings once an account is chosen)
      mappings.where.not(type: mapping_steps.map(&:name)).destroy_all
    end
  end

  # Drops rows and mappings generated from a previous file or account, so the
  # import has to be configured again before it can be published.
  def reset_configuration!
    transaction do
      rows.delete_all
      mappings.delete_all
      refresh_rows_count!
    end
  end

  def mapping_steps
    []
  end

  def uploaded?
    raw_file_str.present?
  end

  def configured?
    uploaded? && rows_count > 0
  end

  def cleaned?
    configured? && rows.all?(&:valid?)
  end

  def publishable?
    cleaned? && mappings_valid?
  end

  def has_unassigned_account?
    mappings.accounts.where(key: "").any?
  end

  def requires_account?
    family.accounts.empty? && has_unassigned_account?
  end

  # Used to optionally pre-fill the configuration for the current import
  def suggested_template
    family.imports
          .complete
          .where(account: account, type: type)
          .order(created_at: :desc)
          .first
  end

  def requires_csv_workflow?
    true
  end

  def apply_template!(import_template)
    update!(
      import_template.attributes.slice(
        "date_col_label", "amount_col_label", "name_col_label",
        "category_col_label", "tags_col_label", "account_col_label",
        "qty_col_label", "ticker_col_label", "price_col_label",
        "entity_type_col_label", "notes_col_label", "currency_col_label",
        "date_format", "signage_convention", "number_format",
        "exchange_operating_mic_col_label",
        "rows_to_skip"
      )
    )
  end

  def max_row_count
    10000
  end

  private
    # Events write the state without validations: uploads are saved with
    # validate: false, and a state change must never be blocked by configuration errors.
    def aasm_save
      save(validate: false)
    end

    def clear_error(*)
      self.error = nil
    end

    def assign_error(message = nil, *)
      self.error = message.to_s.truncate(1000).presence
    end

    def assign_stale_error(*)
      self.error = "Timed out after #{STALE_AFTER.inspect} without finishing"
    end

    # Overridden by PdfImport: a new PDF import is pending until its AI processing starts.
    def awaiting_processing?
      false
    end

    # Overridden by imports whose data cannot be removed again.
    def supports_revert?
      true
    end

    def record_failure(event, error)
      Rails.logger.error("Import #{id} #{event}: #{error.class.name} - #{error.message}")
      aasm.fire!(event, error.message)
    rescue AASM::InvalidTransition, ActiveRecord::RecordNotFound => transition_error
      Rails.logger.error("Import #{id} could not record #{event}: #{transition_error.message}")
    end

    # Only mappings of the current steps count; stale types are removed by #sync_mappings.
    def mappings_valid?
      current_types = mapping_steps.map(&:name)
      mappings.select { |mapping| mapping.type.in?(current_types) }.all?(&:valid?)
    end

    def refresh_rows_count!
      update_column(:rows_count, rows.count)
    end

    # Restores entries this import took over as duplicates. An entry whose previous
    # owner import has since been reverted or deleted goes with this import.
    def release_claimed_entries!
      claimed_entries.includes(:entry).find_each do |claim|
        entry = claim.entry

        if claim.previous_import_id.present? && !Import.where(id: claim.previous_import_id).where.not(status: "reverted").exists?
          next
        end

        entry.update_columns(import_id: claim.previous_import_id, notes: claim.previous_notes, import_locked: claim.previous_import_locked)

        if (txn = entry.transaction)
          txn.update!(category_id: claim.previous_category_id)
          txn.tag_ids = claim.previous_tag_ids
        end
      end

      claimed_entries.delete_all
    end

    # Accounts this import created are removed, unless something else was added to them
    # later; those are kept and only detached from the import.
    def remove_created_accounts!
      accounts.each do |account|
        if account_has_other_data?(account)
          account.update_columns(import_id: nil)
        else
          account.destroy!
        end
      end
    end

    # Entries not written by this import, ignoring the opening balance the import created.
    def account_has_other_data?(account)
      opening_anchor_ids = account.entries.where(entryable_type: "Valuation")
                                  .joins("INNER JOIN valuations ON valuations.id = entries.entryable_id")
                                  .where(valuations: { kind: "opening_anchor" })
                                  .select(:id)

      account.entries.where("entries.import_id IS DISTINCT FROM ?", id)
             .where.not(id: opening_anchor_ids)
             .exists?
    end

    def row_count_exceeded?
      rows_count > max_row_count
    end

    def import!
      # no-op, subclasses can implement for customization of algorithm
    end

    def default_row_name
      "Imported item"
    end

    def default_currency
      account&.currency || family.currency
    end

    def parsed_csv
      return @parsed_csv if defined?(@parsed_csv)

      csv_content = raw_file_str || ""
      if rows_to_skip.to_i > 0
        csv_content = csv_content.lines.drop(rows_to_skip).join
      end

      @parsed_csv = self.class.parse_csv_str(csv_content, col_sep: col_sep)
    end

    def sanitize_number(value)
      return "" if value.nil?

      format = NUMBER_FORMATS[number_format]
      return "" unless format

      # First, normalize spaces and remove any characters that aren't numbers, delimiters, separators, or minus signs
      sanitized = value.to_s.strip

      # Handle French/Scandinavian format specially
      if format[:delimiter] == " "
        sanitized = sanitized.gsub(/\s+/, "") # Remove all spaces first
      else
        sanitized = sanitized.gsub(/[^\d#{Regexp.escape(format[:delimiter])}#{Regexp.escape(format[:separator])}\-]/, "")

        # Replace delimiter with empty string
        if format[:delimiter].present?
          sanitized = sanitized.gsub(format[:delimiter], "")
        end
      end

      # Replace separator with period for proper float parsing
      if format[:separator].present?
        sanitized = sanitized.gsub(format[:separator], ".")
      end

      # Return empty string if not a valid number
      unless sanitized =~ /\A-?\d+\.?\d*\z/
        return ""
      end

      sanitized
    end

    def set_default_number_format
      self.number_format ||= "1,234.56" # Default to US/UK format
    end

    # Common encodings to try when UTF-8 detection fails
    # Windows-1250 is prioritized for Central/Eastern European languages
    COMMON_ENCODINGS = [ "Windows-1250", "Windows-1252", "ISO-8859-1", "ISO-8859-2" ].freeze

    def ensure_utf8_encoding
      # Handle nil or empty string first (before checking if changed)
      return if raw_file_str.nil? || raw_file_str.bytesize == 0

      # Only process if the attribute was changed
      # Use will_save_change_to_attribute? which is safer for binary data
      return unless will_save_change_to_raw_file_str?

      # If already valid UTF-8, nothing to do
      begin
        if raw_file_str.encoding == Encoding::UTF_8 && raw_file_str.valid_encoding?
          return
        end
      rescue ArgumentError
        # raw_file_str might have invalid encoding, continue to detection
      end

      # Detect encoding using rchardet
      begin
        require "rchardet"
        detection = CharDet.detect(raw_file_str)
        detected_encoding = detection["encoding"]
        confidence = detection["confidence"]

        # Only convert if we have reasonable confidence in the detection
        if detected_encoding && confidence > 0.75
          # Force encoding and convert to UTF-8
          self.raw_file_str = raw_file_str.force_encoding(detected_encoding).encode("UTF-8", invalid: :replace, undef: :replace)
        else
          # Fallback: try common encodings
          try_common_encodings
        end
      rescue LoadError
        # rchardet not available, fallback to trying common encodings
        try_common_encodings
      rescue ArgumentError, Encoding::CompatibilityError => e
        # Handle encoding errors by falling back to common encodings
        try_common_encodings
      end
    end

    def try_common_encodings
      COMMON_ENCODINGS.each do |encoding|
        begin
          test = raw_file_str.dup.force_encoding(encoding)
          if test.valid_encoding?
            self.raw_file_str = test.encode("UTF-8", invalid: :replace, undef: :replace)
            return
          end
        rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
          next
        end
      end

      # If nothing worked, force UTF-8 and replace invalid bytes
      self.raw_file_str = raw_file_str.force_encoding("UTF-8").scrub("?")
    end

    def account_belongs_to_family
      return if account.nil?
      return if account.family_id == family_id

      errors.add(:account, "must belong to your family")
    end

    def rows_to_skip_within_file_bounds
      return if raw_file_str.blank?
      return if rows_to_skip.to_i == 0

      line_count = raw_file_str.lines.count

      if rows_to_skip.to_i >= line_count
        errors.add(:rows_to_skip, "must be less than the number of lines in the file (#{line_count})")
      end
    end
end
