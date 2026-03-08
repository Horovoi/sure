require "set"
require "stringio"

class Provider::Openai::BankStatementExtractor
  include Provider::Openai::Concerns::UsageRecorder

  MAX_CHARS_PER_CHUNK = 3000

  attr_reader :client, :pdf_content, :model, :family, :custom_provider

  def initialize(client:, pdf_content:, model:, family: nil, custom_provider: false)
    @client = client
    @pdf_content = pdf_content
    @model = model
    @family = family
    @custom_provider = custom_provider
  end

  def extract
    pages = extract_pages_from_pdf
    raise Provider::Openai::Error, "Could not extract text from PDF" if pages.empty?

    chunks = build_chunks(pages)
    all_transactions = []
    metadata = {}

    chunks.each_with_index do |chunk, index|
      result = process_chunk(chunk, is_first_chunk: index.zero?)
      tagged_transactions = Array(result[:transactions]).map { |transaction| transaction.merge(chunk_index: index) }
      all_transactions.concat(tagged_transactions)

      if index.zero?
        metadata = result.except(:transactions)
      else
        metadata[:closing_balance] = result[:closing_balance] if result[:closing_balance].present?
        if result.dig(:period, :end_date).present?
          metadata[:period] ||= {}
          metadata[:period][:end_date] = result.dig(:period, :end_date)
        end
      end
    end

    {
      transactions: deduplicate_transactions(all_transactions),
      period: metadata[:period] || {},
      account_holder: metadata[:account_holder],
      account_number: metadata[:account_number],
      bank_name: metadata[:bank_name],
      opening_balance: metadata[:opening_balance],
      closing_balance: metadata[:closing_balance]
    }
  end

  private
    def extract_pages_from_pdf
      return [] if pdf_content.blank?

      reader = PDF::Reader.new(StringIO.new(pdf_content))
      reader.pages.map(&:text).reject(&:blank?)
    rescue => error
      Rails.logger.error("Failed to extract text from PDF: #{error.message}")
      []
    end

    def build_chunks(pages)
      chunks = []
      current_chunk = []
      current_size = 0

      pages.each do |page_text|
        if page_text.length > MAX_CHARS_PER_CHUNK
          chunks << current_chunk.join("\n\n") if current_chunk.any?
          current_chunk = []
          current_size = 0
          chunks << page_text
          next
        end

        if current_size + page_text.length > MAX_CHARS_PER_CHUNK && current_chunk.any?
          chunks << current_chunk.join("\n\n")
          current_chunk = []
          current_size = 0
        end

        current_chunk << page_text
        current_size += page_text.length
      end

      chunks << current_chunk.join("\n\n") if current_chunk.any?
      chunks
    end

    def process_chunk(text, is_first_chunk:)
      response = client.chat(parameters: {
        model: model,
        messages: [
          { role: "system", content: is_first_chunk ? instructions_with_metadata : instructions_transactions_only },
          { role: "user", content: "Extract transactions:\n\n#{text}" }
        ],
        response_format: { type: "json_object" }
      })

      record_usage(
        model,
        response["usage"],
        operation: "extract_bank_statement",
        metadata: { chunk_length: text.length, with_metadata: is_first_chunk }
      )

      parsed = parse_json_response(response.dig("choices", 0, "message", "content"))
      {
        transactions: normalize_transactions(parsed["transactions"] || []),
        period: {
          start_date: parsed.dig("statement_period", "start_date"),
          end_date: parsed.dig("statement_period", "end_date")
        },
        account_holder: parsed["account_holder"],
        account_number: parsed["account_number"],
        bank_name: parsed["bank_name"],
        opening_balance: parsed["opening_balance"],
        closing_balance: parsed["closing_balance"]
      }
    rescue => error
      record_usage_error(
        model,
        operation: "extract_bank_statement",
        error: error,
        metadata: { chunk_length: text.length, with_metadata: is_first_chunk }
      )
      raise
    end

    def parse_json_response(content)
      cleaned = content.to_s.gsub(%r{^```json\s*}i, "").gsub(/```\s*$/, "").strip
      JSON.parse(cleaned)
    rescue JSON::ParserError => error
      Rails.logger.error("BankStatementExtractor JSON parse error: #{error.message} (content_length=#{content.to_s.bytesize})")
      { "transactions" => [] }
    end

    def deduplicate_transactions(transactions)
      seen = Set.new

      transactions.select do |transaction|
        key = [ transaction[:date], transaction[:amount], transaction[:name], transaction[:chunk_index] ]
        duplicate = seen.any? do |previous_key|
          previous_key[0..2] == key[0..2] && (previous_key[3] - key[3]).abs <= 1
        end

        seen << key
        !duplicate
      end.map { |transaction| transaction.except(:chunk_index) }
    end

    def normalize_transactions(transactions)
      transactions.map do |txn|
        {
          date: parse_date(txn["date"]),
          amount: parse_amount(txn["amount"]),
          name: txn["description"] || txn["name"] || txn["merchant"],
          category: txn["category"] || txn["type"],
          notes: txn["reference"] || txn["notes"]
        }
      end.reject { |txn| txn[:date].blank? || txn[:amount].nil? || txn[:name].blank? }
    end

    def parse_date(date_str)
      return nil if date_str.blank?

      Date.parse(date_str).strftime("%Y-%m-%d")
    rescue ArgumentError
      nil
    end

    def parse_amount(amount)
      return nil if amount.nil?

      if amount.is_a?(Numeric)
        amount.to_f
      else
        amount.to_s.gsub(/[^0-9.\-]/, "").to_f
      end
    end

    def instructions_with_metadata
      <<~INSTRUCTIONS.strip
        Extract bank statement data as JSON. Return:
        {"bank_name":"...","account_holder":"...","account_number":"last 4 digits","statement_period":{"start_date":"YYYY-MM-DD","end_date":"YYYY-MM-DD"},"opening_balance":0.00,"closing_balance":0.00,"transactions":[{"date":"YYYY-MM-DD","description":"...","amount":-0.00}]}

        Rules: Negative amounts for debits/expenses, positive for credits/deposits. Dates as YYYY-MM-DD. Extract ALL transactions. JSON only, no markdown.
      INSTRUCTIONS
    end

    def instructions_transactions_only
      <<~INSTRUCTIONS.strip
        Extract transactions from bank statement text as JSON. Return:
        {"transactions":[{"date":"YYYY-MM-DD","description":"...","amount":-0.00}]}

        Rules: Negative amounts for debits/expenses, positive for credits/deposits. Dates as YYYY-MM-DD. Extract ALL transactions. JSON only, no markdown.
      INSTRUCTIONS
    end
end
