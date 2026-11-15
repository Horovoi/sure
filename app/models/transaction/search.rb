class Transaction::Search
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :search, :string
  attribute :amount, :string
  attribute :amount_operator, :string
  attribute :types, array: true
  attribute :status, array: true
  attribute :accounts, array: true
  attribute :account_ids, array: true
  attribute :start_date, :string
  attribute :end_date, :string
  attribute :categories, array: true
  attribute :merchants, array: true
  attribute :tags, array: true
  attribute :active_accounts_only, :boolean, default: true

  attr_reader :family

  def initialize(family, filters: {})
    @family = family
    super(filters)
  end

  def transactions_scope
    @transactions_scope ||= begin
      # This already joins entries + accounts. To avoid expensive double-joins, don't join them again (causes full table scan)
      query = family.transactions

      query = apply_active_accounts_filter(query, active_accounts_only)
      query = apply_category_filter(query, categories)
      query = apply_type_filter(query, types)
      query = apply_status_filter(query, status)
      query = apply_merchant_filter(query, merchants)
      query = apply_tag_filter(query, tags)
      # Enforce minimum search length of 2 characters for name search
      query = EntrySearch.apply_search_filter(query, search.to_s.length >= 2 ? search : nil)
      query = EntrySearch.apply_date_filters(query, start_date, end_date)
      query = EntrySearch.apply_amount_filter(query, amount, amount_operator)
      query = EntrySearch.apply_accounts_filter(query, accounts, account_ids)

      query
    end
  end

  # Computes totals for the specific search
  def totals
    @totals ||= begin
      # v2: Totals gained the transfer inflow and outflow (w2-transfers transfer-hints)
      # v3: the No merchant and Untagged filter options (w3-toolstrx filter-options)
      Rails.cache.fetch("transaction_search_totals/v3/#{cache_key_base}", expires_in: Family::AGGREGATE_CACHE_TTL) do
        # The nearest stored rate of the entry's day; an amount in a currency with no rate
        # at all is left out, not counted at 1
        rate = ExchangeRate.rate_sql(
          from: "entries.currency",
          to: ActiveRecord::Base.connection.quote(family.currency),
          on: "entries.date"
        )

        result = transactions_scope
                  .select(
                    "COALESCE(SUM(CASE WHEN entries.excluded THEN 0 WHEN transactions.kind = 'investment_contribution' THEN ABS(entries.amount * #{rate}) WHEN entries.amount >= 0 AND transactions.kind NOT IN ('funds_movement', 'cc_payment') THEN ABS(entries.amount * #{rate}) ELSE 0 END), 0) as expense_total",
                    "COALESCE(SUM(CASE WHEN entries.excluded THEN 0 WHEN entries.amount < 0 AND transactions.kind NOT IN ('funds_movement', 'cc_payment', 'investment_contribution') THEN ABS(entries.amount * #{rate}) ELSE 0 END), 0) as income_total",
                    # Transfers are neither income nor spending; a list filtered to them shows
                    # what came in and went out instead (transactions/_summary)
                    "COALESCE(SUM(CASE WHEN entries.excluded THEN 0 WHEN entries.amount < 0 AND transactions.kind IN ('funds_movement', 'cc_payment') THEN ABS(entries.amount * #{rate}) ELSE 0 END), 0) as transfer_inflow_total",
                    "COALESCE(SUM(CASE WHEN entries.excluded THEN 0 WHEN entries.amount >= 0 AND transactions.kind IN ('funds_movement', 'cc_payment') THEN ABS(entries.amount * #{rate}) ELSE 0 END), 0) as transfer_outflow_total",
                    "COUNT(entries.id) as transactions_count"
                  )
                  .take

        Totals.new(
          count: result.transactions_count.to_i,
          income_money: Money.new(result.income_total, family.currency),
          expense_money: Money.new(result.expense_total, family.currency),
          transfer_inflow_money: Money.new(result.transfer_inflow_total, family.currency),
          transfer_outflow_money: Money.new(result.transfer_outflow_total, family.currency)
        )
      end
    end
  end

  def cache_key_base
    [
      family.id,
      Digest::SHA256.hexdigest(attributes.sort.to_h.to_json), # cached by filters
      family.entries_cache_version,
      ExchangeRate.conversion_cache_key(family.currency) # a rate stored later can complete the totals
    ].join("/")
  end

  private
    Totals = Data.define(:count, :income_money, :expense_money, :transfer_inflow_money, :transfer_outflow_money)

    def apply_active_accounts_filter(query, active_accounts_only_filter)
      if active_accounts_only_filter
        query.merge(Account.visible)
      else
        query
      end
    end


    def apply_category_filter(query, categories)
      return query unless categories.present?

      # The Uncategorized sentinel, or the display name older links still send
      include_uncategorized = categories.any? { |c| Category.uncategorized_filter_value?(c) }
      named_categories = categories.reject { |c| Category.uncategorized_filter_value?(c) }

      # Get parent category IDs so subcategories are included when a parent is selected
      parent_category_ids = named_categories.present? ?
        family.categories.where(name: named_categories).pluck(:id) : []

      conditions = []
      binds = []

      if named_categories.present?
        if parent_category_ids.present?
          conditions << "categories.name IN (?) OR categories.parent_id IN (?)"
          binds.push(named_categories, parent_category_ids)
        else
          conditions << "categories.name IN (?)"
          binds.push(named_categories)
        end
      end

      if include_uncategorized
        # The legs of a transfer between own accounts have nothing to categorize (the same
        # kinds the categorize wizard leaves out)
        conditions << "(categories.id IS NULL AND transactions.kind NOT IN (?))"
        binds.push(Transaction::UNCATEGORIZED_EXCLUDED_KINDS)
      end

      return query if conditions.empty?

      query.left_joins(:category).where(conditions.join(" OR "), *binds)
    end

    def apply_type_filter(query, types)
      return query unless types.present?
      return query if types.sort == [ "expense", "income", "transfer" ]

      transfer, expense, income = Transaction.type_conditions.values_at(:transfer, :expense, :income)

      condition = case types.sort
      when [ "transfer" ]
        transfer
      when [ "expense" ]
        expense.and(transfer.not)
      when [ "income" ]
        income.and(transfer.not)
      when [ "expense", "transfer" ]
        expense.or(transfer)
      when [ "income", "transfer" ]
        income.or(transfer)
      when [ "expense", "income" ]
        transfer.not
      end

      query.where(condition)
    end

    # Merchant names, plus the "No merchant" sentinel for transactions without one
    def apply_merchant_filter(query, merchants)
      return query unless merchants.present?

      include_no_merchant = merchants.include?(Merchant::NO_MERCHANT_FILTER_VALUE)
      named = merchants - [ Merchant::NO_MERCHANT_FILTER_VALUE ]

      if include_no_merchant
        query.left_joins(:merchant).where("merchants.name IN (?) OR transactions.merchant_id IS NULL", named)
      else
        query.joins(:merchant).where(merchants: { name: named })
      end
    end

    # Tag names, plus the "Untagged" sentinel for transactions without a tag. Subqueries,
    # not a join: joining tags gives one row per matching tag, so a transaction with two of
    # the filtered tags was counted and summed twice in totals.
    def apply_tag_filter(query, tags)
      return query unless tags.present?

      include_untagged = tags.include?(Tag::UNTAGGED_FILTER_VALUE)
      named = tags - [ Tag::UNTAGGED_FILTER_VALUE ]
      transactions = Transaction.arel_table

      tagged = transactions[:id].in(EntrySearch.tagged_transaction_ids(named).arel) if named.any?
      untagged = EntrySearch.untagged_condition(transactions[:id]) if include_untagged

      query.where([ tagged, untagged ].compact.reduce(:or))
    end

    def apply_status_filter(query, statuses)
      return query unless statuses.present?
      return query if statuses.uniq.sort == [ "confirmed", "pending" ] # Both selected = no filter

      pending_condition = <<~SQL.squish
        EXISTS (
          SELECT 1 FROM jsonb_each(transactions.extra) AS pd
          WHERE (pd.value ->> 'pending')::boolean = true
        )
      SQL

      confirmed_condition = <<~SQL.squish
        NOT EXISTS (
          SELECT 1 FROM jsonb_each(transactions.extra) AS pd
          WHERE (pd.value ->> 'pending')::boolean = true
        )
      SQL

      case statuses.sort
      when [ "pending" ]
        query.where(pending_condition)
      when [ "confirmed" ]
        query.where(confirmed_condition)
      else
        query
      end
    end
end
