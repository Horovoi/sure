require "digest/md5"

class LunchflowEntry::Processor
  include CurrencyNormalizable
  # lunchflow_transaction is the raw hash fetched from Lunchflow API and converted to JSONB
  # Transaction structure: { id, accountId, amount, currency, date, merchant, description }
  def initialize(lunchflow_transaction, lunchflow_account:)
    @lunchflow_transaction = lunchflow_transaction
    @lunchflow_account = lunchflow_account
  end

  def process
    # Validate that we have a linked account before processing
    unless account.present?
      Rails.logger.warn "LunchflowEntry::Processor - No linked account for lunchflow_account #{lunchflow_account.id}, skipping transaction #{external_id}"
      return nil
    end

    if pending? && external_id.start_with?("lunchflow_pending_")
      existing_posted = find_existing_posted_version
      if existing_posted
        Rails.logger.info "LunchflowEntry::Processor - Skipping pending transaction (posted version already exists): pending=#{external_id}, posted=#{existing_posted.external_id}"
        return existing_posted
      end
    end

    # Wrap import in error handling to catch validation and save errors
    begin
      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: name,
        source: "lunchflow",
        merchant: merchant,
        notes: notes
      )
    rescue ArgumentError => e
      # Re-raise validation errors (missing required fields, invalid data)
      Rails.logger.error "LunchflowEntry::Processor - Validation error for transaction #{external_id}: #{e.message}"
      raise
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      # Handle database save errors
      Rails.logger.error "LunchflowEntry::Processor - Failed to save transaction #{external_id}: #{e.message}"
      raise StandardError.new("Failed to import transaction: #{e.message}")
    rescue => e
      # Catch unexpected errors with full context
      Rails.logger.error "LunchflowEntry::Processor - Unexpected error processing transaction #{external_id}: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise StandardError.new("Unexpected error importing transaction: #{e.message}")
    end
  end

  private
    attr_reader :lunchflow_transaction, :lunchflow_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= lunchflow_account.current_account
    end

    def data
      @data ||= lunchflow_transaction.with_indifferent_access
    end

    def external_id
      @external_id ||= calculate_external_id
    end

    def calculate_external_id
      id = data[:id].presence
      return "lunchflow_#{id}" if id.present?

      raise ArgumentError, "Lunchflow pending transaction missing required fields for temporary ID generation" unless pending?

      fingerprint_parts = [
        data[:accountId],
        data[:merchant].presence || name,
        amount.to_s("F"),
        currency,
        date.iso8601
      ]
      digest = Digest::SHA256.hexdigest(fingerprint_parts.join("|")).first(24)
      "lunchflow_pending_#{digest}"
    end

    def name
      data[:merchant].presence || "Unknown transaction"
    end

    def notes
      data[:description].presence
    end

    def merchant
      return nil unless data[:merchant].present?

      # Create a stable merchant ID from the merchant name
      # Using digest to ensure uniqueness while keeping it deterministic
      merchant_name = data[:merchant].to_s.strip
      return nil if merchant_name.blank?

      merchant_id = Digest::MD5.hexdigest(merchant_name.downcase)

      @merchant ||= begin
        import_adapter.find_or_create_merchant(
          provider_merchant_id: "lunchflow_merchant_#{merchant_id}",
          name: merchant_name,
          source: "lunchflow"
        )
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "LunchflowEntry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
        nil
      end
    end

    def amount
      parsed_amount = case data[:amount]
      when String
        BigDecimal(data[:amount])
      when Numeric
        BigDecimal(data[:amount].to_s)
      else
        BigDecimal("0")
      end

      # Lunchflow likely uses standard convention where negative is expense, positive is income
      # Maybe expects opposite convention (expenses positive, income negative)
      # So we negate the amount to convert from Lunchflow to Maybe format
      -parsed_amount
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse Lunchflow transaction amount: #{data[:amount].inspect} - #{e.message}"
      raise
    end

    def currency
      parse_currency(data[:currency]) || account&.currency || "USD"
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in LunchFlow transaction #{external_id}, falling back to account currency")
    end

    def pending?
      ActiveModel::Type::Boolean.new.cast(data[:isPending])
    end

    def find_existing_posted_version
      return nil unless account.present?

      query = account.entries
        .where(source: "lunchflow")
        .where(amount: amount)
        .where(currency: currency)
        .where("date BETWEEN ? AND ?", date, date + 8)
        .where("external_id NOT LIKE 'lunchflow_pending_%'")
        .where.not(external_id: nil)
        .order(date: :asc)

      query = query.where(name: name) if data[:merchant].present?
      query.first
    end

    def date
      case data[:date]
      when String
        Date.parse(data[:date])
      when Integer, Float
        # Unix timestamp
        Time.at(data[:date]).to_date
      when Time, DateTime
        data[:date].to_date
      when Date
        data[:date]
      else
        Rails.logger.error("Lunchflow transaction has invalid date value: #{data[:date].inspect}")
        raise ArgumentError, "Invalid date format: #{data[:date].inspect}"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse Lunchflow transaction date '#{data[:date]}': #{e.message}")
      raise ArgumentError, "Unable to parse transaction date: #{data[:date].inspect}"
    end
end
