# One monobank product: a card or currency account (kind "card", FOP accounts are
# cards of type "fop") or a jar (kind "jar"). Amounts from monobank are integers
# in the currency's minor units; balances here are in major units.
#
# Statement rows are kept in raw_transactions_payload until they are processed into
# entries; settled rows older than RAW_RETENTION are dropped after a good pass. The
# fetch state (cursors, paging, backoff) is read by MonobankItem::FetchPlan.
class MonobankAccount < ApplicationRecord
  include CurrencyNormalizable, IsoNumericCurrency, Encryptable

  CARD_KIND = "card".freeze
  JAR_KIND = "jar".freeze

  CARD_TYPES = %w[black white platinum iron yellow eaid fop].freeze

  INSTITUTION_NAME = "monobank".freeze
  INSTITUTION_DOMAIN = "monobank.ua".freeze

  RAW_RETENTION = 35.days

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :monobank_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, :account_id, :account_kind, presence: true
  validates :account_id, uniqueness: { scope: :monobank_item_id }
  validates :account_kind, inclusion: { in: [ CARD_KIND, JAR_KIND ] }

  scope :unlinked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :needs_setup, -> { unlinked.where(ignored: false) }
  scope :ordered, -> { order(:account_kind, :currency, :name) }

  # The hand-kept account each product most likely is, for the setup dialog:
  # same currency and type, and "mono" in its name (the owner's "Mono Visa").
  # Credit cards first, each account suggested once. { monobank_account.id => Account }
  def self.suggest_links(monobank_accounts, candidates)
    used = Set.new
    monobank_accounts.sort_by { |ma| ma.credit_card? ? 0 : 1 }.each_with_object({}) do |monobank_account, result|
      match = candidates.find do |account|
        !used.include?(account.id) &&
          account.currency == monobank_account.currency &&
          account.accountable_type == monobank_account.suggested_account_type &&
          account.name.to_s.match?(/mono/i)
      end
      next unless match

      used << match.id
      result[monobank_account.id] = match
    end
  end

  def current_account
    account
  end

  def jar?
    account_kind == JAR_KIND
  end

  def fop?
    account_type == "fop"
  end

  def credit_card?
    !jar? && credit_limit.to_d.positive?
  end

  # Suggested Sure type: a card with a credit limit is a credit card, an unknown
  # card type is asked in setup (nil), everything else is cash.
  def suggested_account_type
    return "Depository" if jar?
    return nil unless account_type.to_s.downcase.in?(CARD_TYPES)

    credit_card? ? "CreditCard" : "Depository"
  end

  def suggested_subtype
    case suggested_account_type
    when "CreditCard" then "credit_card"
    when "Depository" then jar? ? "savings" : "checking"
    end
  end

  def type_label
    return I18n.t("monobank_items.card_types.jar") if jar?

    I18n.t("monobank_items.card_types.#{account_type.to_s.downcase.presence || 'unknown'}",
           default: I18n.t("monobank_items.card_types.unknown"))
  end

  def iban
    raw_payload.to_h["iban"].presence
  end

  def divisor
    minor_unit_divisor(currency)
  end

  # Raw client-info balance including the credit limit, in major units
  def raw_balance
    return nil if raw_balance_minor.nil?

    BigDecimal(raw_balance_minor.to_s) / divisor
  end

  # Balance in the terms of a Sure account type: own funds for cash accounts,
  # debt (limit minus available) for a credit card.
  def balance_for(accountable_type)
    return nil if raw_balance.nil?

    limit = credit_limit.to_d
    accountable_type == "CreditCard" ? limit - raw_balance : raw_balance - limit
  end

  # Stores a card or jar from client-info (as flattened by Provider::Monobank#get_accounts)
  def upsert_monobank_snapshot!(snapshot)
    data = snapshot.to_h.with_indifferent_access
    kind = data[:kind].presence || CARD_KIND
    alpha = alpha_currency_code(data[:currencyCode])
    log_invalid_currency(data[:currencyCode]) if data[:currencyCode].present? && alpha.blank?
    currency_code = parse_currency(alpha) || currency || "UAH"
    div = minor_unit_divisor(currency_code)

    raw_balance_value = integer_or_nil(data[:balance])
    limit_minor = integer_or_nil(data[:creditLimit]) || 0
    pan = Array(data[:maskedPan]).first.to_s

    assign_attributes(
      account_id: data[:id].to_s,
      account_kind: kind,
      account_type: kind == JAR_KIND ? JAR_KIND : data[:type].presence,
      currency: currency_code,
      raw_balance_minor: raw_balance_value,
      credit_limit: BigDecimal(limit_minor.to_s) / div,
      current_balance: raw_balance_value && (BigDecimal((raw_balance_value - limit_minor).to_s) / div),
      goal: data[:goal].present? ? BigDecimal(data[:goal].to_s) / div : nil,
      last4: pan.length >= 4 ? pan[-4..] : nil,
      raw_payload: data.slice(:id, :kind, :type, :currencyCode, :cashbackType, :balance, :creditLimit, :iban, :title, :goal).to_h
    )
    self.name = display_name(data, kind) if new_record? || name.blank?

    save!
  end

  def append_rows!(rows)
    update!(raw_transactions_payload: rows)
  end

  private
    def display_name(data, kind)
      if kind == JAR_KIND
        data[:title].presence || I18n.t("monobank_items.card_types.jar")
      else
        return "FOP · #{currency}" if fop?

        label = last4.present? ? "#{type_label} ·#{last4}" : type_label
        currency == "UAH" ? label : "#{label} · #{currency}"
      end
    end

    def integer_or_nil(value)
      return nil if value.blank?

      Integer(value.to_s)
    rescue ArgumentError
      nil
    end

    def log_invalid_currency(value)
      Rails.logger.warn("Unknown currency code #{value.inspect} for monobank account #{id}")
    end
end
