require "csv"

class Assistant::Function::ImportBankStatement < Assistant::Function
  class << self
    def name
      "import_bank_statement"
    end

    def description
      <<~DESC
        Extract transactions from an already-uploaded PDF bank or credit-card statement
        and create a transaction import for user review.
      DESC
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "pdf_import_id" ],
      properties: {
        pdf_import_id: {
          type: "string",
          description: "The ID of the PdfImport to process"
        },
        account_id: {
          type: "string",
          description: "Destination account ID. If omitted, the function will return available accounts."
        }
      }
    )
  end

  def call(params = {})
    pdf_import = family.imports.find_by(id: params["pdf_import_id"], type: "PdfImport")

    unless pdf_import
      return {
        success: false,
        error: "not_found",
        message: "Could not find a PDF import with ID: #{params["pdf_import_id"]}"
      }
    end

    unless pdf_import.statement_with_transactions?
      return {
        success: false,
        error: "not_statement",
        message: "This PDF is not a bank or credit-card statement. Document type: #{pdf_import.document_type || 'unknown'}"
      }
    end

    if params["account_id"].blank?
      return {
        success: false,
        error: "account_required",
        message: "Please specify the account to import these transactions into.",
        available_accounts: available_accounts
      }
    end

    account = family.accounts.visible_manual.find_by(id: params["account_id"]) || family.accounts.visible.find_by(id: params["account_id"])
    unless account
      return {
        success: false,
        error: "account_not_found",
        message: "Account not found.",
        available_accounts: available_accounts
      }
    end

    pdf_import.update!(account: account)

    extracted = if pdf_import.has_extracted_transactions?
      pdf_import.extracted_data
    else
      pdf_import.extract_transactions
    end

    unless extracted.present? && Array(extracted["transactions"]).any?
      return {
        success: false,
        error: "no_transactions_found",
        message: "Could not extract any transactions from the statement."
      }
    end

    pdf_import.generate_rows_from_extracted_data
    pdf_import.sync_mappings

    {
      success: true,
      import_id: pdf_import.id,
      transaction_count: pdf_import.rows_count,
      document_type: pdf_import.document_type,
      transactions_preview: Array(extracted["transactions"]).first(5),
      message: "Transactions extracted into import #{pdf_import.id}. Review and publish them in the Imports flow."
    }
  rescue => error
    Rails.logger.error("ImportBankStatement error: #{error.class.name} - #{error.message}")
    {
      success: false,
      error: "extraction_failed",
      message: "Failed to import bank statement: #{error.message.truncate(200)}"
    }
  end

  private
    def available_accounts
      family.accounts.visible_manual.alphabetically.map { |account| { id: account.id, name: account.name } }
    end
end
