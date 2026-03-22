class EntrySearch
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
  TRANSACTIONS_JOIN = "INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'"
  ALL_FILTER_TYPES = %w[balance_update expense income trade transfer].freeze
  ENTRYABLE_TYPE_MAP = {
    "balance_update" => "Valuation",
    "trade" => "Trade"
  }.freeze

  class << self
    def apply_search_filter(scope, search)
      return scope if search.blank?

      query = scope
      query = query.where("entries.name ILIKE :search OR entries.notes ILIKE :search",
        search: "%#{ActiveRecord::Base.sanitize_sql_like(search)}%"
      )
      query
    end

    def apply_date_filters(scope, start_date, end_date)
      return scope if start_date.blank? && end_date.blank?

      query = scope
      query = query.where("entries.date >= ?", start_date) if start_date.present?
      query = query.where("entries.date <= ?", end_date) if end_date.present?
      query
    end

    def apply_amount_filter(scope, amount, amount_operator)
      return scope if amount.blank? || amount_operator.blank?

      query = scope

      case amount_operator
      when "equal"
        query = query.where("ABS(ABS(entries.amount) - ?) <= 0.01", amount.to_f.abs)
      when "less"
        query = query.where("ABS(entries.amount) < ?", amount.to_f.abs)
      when "greater"
        query = query.where("ABS(entries.amount) > ?", amount.to_f.abs)
      end

      query
    end

    def apply_accounts_filter(scope, accounts, account_ids)
      return scope if accounts.blank? && account_ids.blank?

      query = scope
      query = query.where(accounts: { name: accounts }) if accounts.present?
      query = query.where(accounts: { id: account_ids }) if account_ids.present?
      query
    end

    def apply_status_filter(scope, statuses)
      return scope unless statuses.present?
      return scope if statuses.uniq.sort == %w[confirmed pending] # Both selected = no filter

      pending_condition = <<~SQL.squish
        entries.entryable_type = 'Transaction'
        AND EXISTS (
          SELECT 1 FROM transactions t
          WHERE t.id = entries.entryable_id
          AND EXISTS (
            SELECT 1 FROM jsonb_each(t.extra) AS pd
            WHERE (pd.value ->> 'pending')::boolean = true
          )
        )
      SQL

      confirmed_condition = <<~SQL.squish
        entries.entryable_type != 'Transaction'
        OR NOT EXISTS (
          SELECT 1 FROM transactions t
          WHERE t.id = entries.entryable_id
          AND EXISTS (
            SELECT 1 FROM jsonb_each(t.extra) AS pd
            WHERE (pd.value ->> 'pending')::boolean = true
          )
        )
      SQL

      case statuses.sort
      when [ "pending" ]
        scope.where(pending_condition)
      when [ "confirmed" ]
        scope.where(confirmed_condition)
      else
        scope
      end
    end
  end

  def build_query(scope)
    query = scope.joins(:account)
    query = self.class.apply_search_filter(query, search)
    query = self.class.apply_date_filters(query, start_date, end_date)
    query = self.class.apply_amount_filter(query, amount, amount_operator)
    query = self.class.apply_accounts_filter(query, accounts, account_ids)
    query = self.class.apply_status_filter(query, status)

    query = apply_type_conditions(query, types)
    query = apply_category_conditions(query, categories)
    query = apply_merchant_conditions(query, merchants)
    query = apply_tag_conditions(query, tags)
    query
  end

  private

    def apply_type_conditions(query, types)
      return query if types.blank?

      normalized_types = Array(types) & ALL_FILTER_TYPES
      return query if normalized_types.blank?
      return query if normalized_types.sort == ALL_FILTER_TYPES

      entry_types = normalized_types & %w[balance_update trade]
      txn_types = normalized_types & %w[income expense transfer]

      conditions = []

      entry_type_classes = entry_types.map { |type| ENTRYABLE_TYPE_MAP[type] }.compact
      if entry_type_classes.any?
        conditions << "entries.entryable_type IN (#{entry_type_classes.map { |c| ActiveRecord::Base.connection.quote(c) }.join(', ')})"
      end

      txn_condition = build_transaction_type_condition(txn_types)
      conditions << txn_condition if txn_condition

      return query if conditions.empty?
      query.where(conditions.join(" OR "))
    end

    def apply_category_conditions(query, categories)
      return query if categories.blank?

      include_uncategorized = categories.include?("Uncategorized")
      named_categories = categories.reject { |c| c == "Uncategorized" }

      query = query.joins(TRANSACTIONS_JOIN)

      conditions = []
      binds = []

      if named_categories.present?
        # Match by category name OR by parent category name (subcategories included via self-join)
        query = query.joins("LEFT JOIN categories ON categories.id = transactions.category_id")
                     .joins("LEFT JOIN categories AS parent_categories ON parent_categories.id = categories.parent_id")
        conditions << "categories.name IN (?) OR parent_categories.name IN (?)"
        binds.push(named_categories, named_categories)
      end

      if include_uncategorized
        query = query.joins("LEFT JOIN categories ON categories.id = transactions.category_id") unless named_categories.present?
        conditions << "(categories.id IS NULL AND transactions.kind NOT IN ('funds_movement', 'cc_payment'))"
      end

      return query if conditions.empty?
      query.where(conditions.join(" OR "), *binds)
    end

    def apply_merchant_conditions(query, merchants)
      return query if merchants.blank?

      query
        .joins(TRANSACTIONS_JOIN)
        .joins("INNER JOIN merchants ON merchants.id = transactions.merchant_id")
        .where(merchants: { name: merchants })
    end

    def apply_tag_conditions(query, tags)
      return query if tags.blank?

      query
        .joins(TRANSACTIONS_JOIN)
        .joins("INNER JOIN taggings ON taggings.taggable_type = 'Transaction' AND taggings.taggable_id = transactions.id")
        .joins("INNER JOIN tags ON tags.id = taggings.tag_id")
        .where(tags: { name: tags })
    end

    def build_transaction_type_condition(txn_types)
      return if txn_types.blank?

      transfer_condition = transaction_exists_condition(Transaction::TRANSFER_KINDS)
      investment_contribution_condition = transaction_exists_condition([ "investment_contribution" ])
      expense_condition = "(entries.amount >= 0 OR #{investment_contribution_condition})"
      income_condition = "(entries.amount <= 0 AND NOT #{investment_contribution_condition})"

      case txn_types.sort
      when %w[expense income transfer]
        "entries.entryable_type = 'Transaction'"
      when [ "transfer" ]
        transfer_condition
      when [ "expense" ]
        "entries.entryable_type = 'Transaction' AND #{expense_condition} AND NOT (#{transfer_condition})"
      when [ "income" ]
        "entries.entryable_type = 'Transaction' AND #{income_condition} AND NOT (#{transfer_condition})"
      when %w[expense transfer]
        "entries.entryable_type = 'Transaction' AND ((#{expense_condition} AND NOT (#{transfer_condition})) OR #{transfer_condition})"
      when %w[income transfer]
        "entries.entryable_type = 'Transaction' AND ((#{income_condition} AND NOT (#{transfer_condition})) OR #{transfer_condition})"
      when %w[expense income]
        "entries.entryable_type = 'Transaction' AND NOT (#{transfer_condition})"
      end
    end

    def transaction_exists_condition(kinds)
      quoted_kinds = kinds.map { |kind| ActiveRecord::Base.connection.quote(kind) }.join(", ")

      <<~SQL.squish
        EXISTS (
          SELECT 1 FROM transactions t
          WHERE t.id = entries.entryable_id
          AND entries.entryable_type = 'Transaction'
          AND t.kind IN (#{quoted_kinds})
        )
      SQL
    end
end
