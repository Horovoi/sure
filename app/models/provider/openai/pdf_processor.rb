require "base64"
require "json"
require "stringio"
require "tmpdir"

class Provider::Openai::PdfProcessor
  include Provider::Openai::Concerns::UsageRecorder

  attr_reader :client, :model, :pdf_content, :custom_provider, :langfuse_trace, :family

  def initialize(client, model: "", pdf_content: nil, custom_provider: false, langfuse_trace: nil, family: nil)
    @client = client
    @model = model
    @pdf_content = pdf_content
    @custom_provider = custom_provider
    @langfuse_trace = langfuse_trace
    @family = family
  end

  def process
    span = langfuse_trace&.span(name: "process_pdf_api_call", input: {
      model: model.presence || Provider::Openai::DEFAULT_MODEL,
      pdf_size: pdf_content&.bytesize
    })

    response = begin
      process_with_text_extraction
    rescue Provider::Openai::Error => error
      Rails.logger.warn("Text extraction failed: #{error.message}, trying vision API")
      process_with_vision
    end

    span&.end(output: response.to_h)
    response
  rescue => error
    span&.end(output: { error: error.message }, level: "ERROR")
    raise
  end

  def instructions
    <<~INSTRUCTIONS.strip
      You are a financial document analysis assistant. Your job is to analyze uploaded PDF documents
      and provide a structured summary of what the document contains.

      For each document, determine:

      1. Document Type:
         - `bank_statement`
         - `credit_card_statement`
         - `investment_statement`
         - `financial_document`
         - `contract`
         - `other`

      2. Summary:
         - Institution/company if identifiable
         - Date range or statement period if applicable
         - Key balances or financial figures if visible
         - Account holder if visible
         - Any notable information

      3. Extracted Data:
         - transaction_count if countable
         - statement period start/end
         - opening and closing balances if visible
         - currency
         - institution and account holder

      Respond with ONLY valid JSON:
      {
        "document_type": "bank_statement|credit_card_statement|investment_statement|financial_document|contract|other",
        "summary": "Concise summary",
        "extracted_data": {
          "institution_name": "string or null",
          "statement_period_start": "YYYY-MM-DD or null",
          "statement_period_end": "YYYY-MM-DD or null",
          "transaction_count": 0,
          "opening_balance": 0.0,
          "closing_balance": 0.0,
          "currency": "USD",
          "account_holder": "string or null"
        }
      }
    INSTRUCTIONS
  end

  private
    PdfProcessingResult = Provider::LlmConcept::PdfProcessingResult

    def process_with_text_extraction
      effective_model = model.presence || Provider::Openai::DEFAULT_MODEL
      pdf_text = extract_text_from_pdf
      raise Provider::Openai::Error, "Could not extract text from PDF" if pdf_text.blank?

      pdf_text = pdf_text.truncate(100_000) if pdf_text.length > 100_000

      response = client.chat(parameters: {
        model: effective_model,
        messages: [
          { role: "system", content: instructions },
          { role: "user", content: "Please analyze the following document text and provide a structured summary:\n\n#{pdf_text}" }
        ],
        response_format: { type: "json_object" }
      })

      record_usage(
        effective_model,
        response["usage"],
        operation: "process_pdf",
        metadata: { pdf_size: pdf_content&.bytesize }
      )

      parse_response(response)
    rescue => error
      record_usage_error(
        effective_model,
        operation: "process_pdf",
        error: error,
        metadata: { pdf_size: pdf_content&.bytesize }
      )
      raise
    end

    def process_with_vision
      effective_model = model.presence || Provider::Openai::DEFAULT_MODEL
      images_base64 = convert_pdf_to_images
      raise Provider::Openai::Error, "Could not convert PDF to images" if images_base64.blank?

      content = images_base64.first(5).map do |image|
        {
          type: "image_url",
          image_url: {
            url: "data:image/png;base64,#{image}",
            detail: "low"
          }
        }
      end
      content << {
        type: "text",
        text: "Please analyze this PDF document and respond with valid JSON only."
      }

      response = client.chat(parameters: {
        model: effective_model,
        messages: [
          { role: "system", content: "#{instructions}\n\nIMPORTANT: Respond with valid JSON only." },
          { role: "user", content: content }
        ],
        max_tokens: 4096
      })

      record_usage(
        effective_model,
        response["usage"],
        operation: "process_pdf_vision",
        metadata: { pdf_size: pdf_content&.bytesize, pages: images_base64.size }
      )

      parse_response(response)
    rescue => error
      record_usage_error(
        effective_model,
        operation: "process_pdf_vision",
        error: error,
        metadata: { pdf_size: pdf_content&.bytesize }
      )
      raise
    end

    def extract_text_from_pdf
      return nil if pdf_content.blank?

      reader = PDF::Reader.new(StringIO.new(pdf_content))
      text_parts = []

      reader.pages.each_with_index do |page, index|
        text_parts << "--- Page #{index + 1} ---"
        text_parts << page.text
      end

      text_parts.join("\n\n")
    rescue => error
      Rails.logger.error("Failed to extract text from PDF: #{error.message}")
      nil
    end

    def convert_pdf_to_images
      return [] if pdf_content.blank?

      Dir.mktmpdir do |tmpdir|
        pdf_path = File.join(tmpdir, "input.pdf")
        File.binwrite(pdf_path, pdf_content)

        output_prefix = File.join(tmpdir, "page")
        system("pdftoppm", "-png", "-r", "150", pdf_path, output_prefix)

        Dir.glob(File.join(tmpdir, "page-*.png")).sort.map do |image_path|
          Base64.strict_encode64(File.binread(image_path))
        end
      end
    rescue => error
      Rails.logger.error("Failed to convert PDF to images: #{error.message}")
      []
    end

    def parse_response(response)
      raw = response.dig("choices", 0, "message", "content")
      parsed = parse_json_flexibly(raw)

      PdfProcessingResult.new(
        summary: parsed["summary"],
        document_type: normalize_document_type(parsed["document_type"]),
        extracted_data: parsed["extracted_data"] || {}
      )
    end

    def normalize_document_type(document_type)
      return "other" if document_type.blank?

      normalized = document_type.to_s.strip.downcase.gsub(/\s+/, "_")
      Import::DOCUMENT_TYPES.include?(normalized) ? normalized : "other"
    end

    def parse_json_flexibly(raw)
      return {} if raw.blank?

      JSON.parse(raw)
    rescue JSON::ParserError
      if raw =~ /```(?:json)?\s*(\{[\s\S]*?\})\s*```/m
        return JSON.parse($1)
      end

      if raw =~ /(\{[\s\S]*\})/m
        return JSON.parse($1)
      end

      raise Provider::Openai::Error, "Could not parse JSON from PDF processing response: #{raw.truncate(200)}"
    end
end
