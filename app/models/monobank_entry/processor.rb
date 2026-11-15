require "digest/md5"

# One monobank statement row into one entry of the linked account, through
# Account::ProviderImportAdapter.
#
# monobank amounts are minor units of the account currency, negative for money out;
# Sure amounts are major units, positive for money out. currencyCode/operationAmount
# name the operation's own currency and are kept as fx_from/fx_amount.
class MonobankEntry::Processor
  include CurrencyNormalizable, IsoNumericCurrency

  SOURCE = "monobank".freeze

  class << self
    def canonical_external_id(row)
      data = row.to_h.with_indifferent_access
      return "monobank_#{data[:id]}" if data[:id].present?

      "monobank_pending_#{Digest::MD5.hexdigest([ data[:account_id], data[:time], data[:amount], data[:description] ].compact.join('|'))}"
    end

    def pending?(row)
      return false unless row.is_a?(Hash)

      ActiveModel::Type::Boolean.new.cast(row["hold"] || row[:hold]) || false
    end
  end

  attr_reader :row, :monobank_account

  def initialize(row, monobank_account:, import_adapter: nil, claimed_entry: nil, category_id_if_blank: nil, cutover_date: nil)
    @row = row.to_h.with_indifferent_access
    @monobank_account = monobank_account
    @import_adapter = import_adapter
    @claimed_entry = claimed_entry
    @category_id_if_blank = category_id_if_blank
    @cutover_date = cutover_date
  end

  # The entry, or nil when the account is not linked or the row is before the cut-over
  def process
    return nil if account.nil?

    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: SOURCE,
      merchant: merchant,
      notes: notes,
      extra: extra_metadata,
      claimed_entry: @claimed_entry,
      category_id_if_blank: @category_id_if_blank,
      cutover_date: @cutover_date
    )
  end

  def external_id
    @external_id ||= self.class.canonical_external_id(row)
  end

  def pending?
    self.class.pending?(row)
  end

  # Sure sign: positive is money out
  def amount
    -(minor_units(row[:amount]) / account_divisor)
  end

  def date
    value = row[:time]
    raise ArgumentError, "monobank row has no time" if value.blank?

    Time.at(Integer(value.to_s)).in_time_zone(time_zone).to_date
  rescue TypeError
    raise ArgumentError, "monobank row has an invalid time"
  end

  def currency
    monobank_account.currency
  end

  def name
    row[:description].to_s.strip.presence || I18n.t("transactions.unknown_name")
  end

  def description
    row[:description].to_s
  end

  def mcc
    row[:mcc].presence&.to_i
  end

  def original_mcc
    row[:originalMcc].presence&.to_i
  end

  def counter_iban
    row[:counterIban].presence
  end

  private
    def account
      @account ||= monobank_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def time_zone
      account&.family&.resolved_time_zone || Time.zone
    end

    def notes
      row[:comment].presence
    end

    def merchant
      merchant_name = row[:description].to_s.strip.presence
      return nil unless merchant_name

      import_adapter.find_or_create_merchant(
        provider_merchant_id: "monobank_merchant_#{Digest::MD5.hexdigest(merchant_name.downcase)}",
        name: merchant_name,
        source: SOURCE
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("MonobankEntry::Processor - merchant not saved: #{e.message}")
      nil
    end

    def extra_metadata
      {
        SOURCE => {
          "pending" => pending?,
          "time" => row[:time].to_i,
          "mcc" => row[:mcc],
          "original_mcc" => row[:originalMcc],
          "cashback_amount" => major_amount(row[:cashbackAmount]),
          "commission_amount" => major_amount(row[:commissionRate]),
          "balance_after" => major_amount(row[:balance]),
          "operation_amount" => foreign_operation_amount,
          "fx_from" => fx_from,
          "fx_amount" => fx_amount,
          "counter_name" => row[:counterName].presence,
          "counter_iban" => row[:counterIban].presence,
          "counter_edrpou" => row[:counterEdrpou].presence,
          "receipt_id" => row[:receiptId].presence,
          "invoice_id" => row[:invoiceId].presence
        }.compact
      }
    end

    def foreign_operation_amount
      value = row[:operationAmount]
      return nil if value.blank? || value.to_s == row[:amount].to_s

      value
    end

    def operation_currency
      return @operation_currency if defined?(@operation_currency)

      @operation_currency = parse_currency(alpha_currency_code(row[:currencyCode]))
    end

    def foreign_operation?
      operation_currency.present? && operation_currency != currency
    end

    def fx_from
      operation_currency if foreign_operation?
    end

    def fx_amount
      return nil unless foreign_operation? && row[:operationAmount].present?

      (minor_units(row[:operationAmount]) / BigDecimal(minor_unit_divisor(operation_currency).to_s)).to_s("F")
    rescue ArgumentError
      nil
    end

    def account_divisor
      @account_divisor ||= BigDecimal(minor_unit_divisor(currency).to_s)
    end

    def minor_units(value)
      return BigDecimal("0") if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      raise ArgumentError, "monobank row has an invalid amount"
    end

    def major_amount(value)
      return nil if value.blank?

      (minor_units(value) / account_divisor).to_s("F")
    rescue ArgumentError
      nil
    end

    def log_invalid_currency(value)
      Rails.logger.warn("Unknown currency code #{value.inspect} in monobank row #{external_id}")
    end
end
