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
  attribute :attachment_status, array: true
  TRANSACTIONS_JOIN = "INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'"
  ALL_FILTER_TYPES = %w[balance_update expense income trade transfer].freeze
  ENTRYABLE_TYPE_MAP = {
    "balance_update" => "Valuation",
    "trade" => "Trade"
  }.freeze

  class << self
    # Ids of the transactions that carry at least one of the named tags, once each.
    # The caller's scope limits the result to its family.
    def tagged_transaction_ids(tags)
      Tagging.joins(:tag).where(taggable_type: "Transaction", tags: { name: tags }).select(:taggable_id)
    end

    # NOT EXISTS over the taggings of the transaction whose id is transaction_id (an Arel
    # attribute), for the "Untagged" filter option
    def untagged_condition(transaction_id)
      taggings = Tagging.arel_table
      Arel::Nodes::Not.new(
        Tagging.where(taggable_type: "Transaction").where(taggings[:taggable_id].eq(transaction_id)).arel.exists
      )
    end

    # EXISTS over the files of the transaction whose id is transaction_id (an Arel
    # attribute), for the attachment filter (w3-toolstrx transaction-attachments)
    def attachment_condition(transaction_id)
      attachments = ActiveStorage::Attachment.arel_table

      ActiveStorage::Attachment
        .where(record_type: "Transaction", name: "attachments")
        .where(attachments[:record_id].eq(transaction_id))
        .select(1)
        .arel
        .exists
    end

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
    query = apply_attachment_conditions(query, attachment_status)
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
      conditions << Entry.arel_table[:entryable_type].in(entry_type_classes) if entry_type_classes.any?

      txn_condition = build_transaction_type_condition(txn_types)
      conditions << txn_condition if txn_condition

      return query if conditions.empty?
      query.where(conditions.reduce(:or))
    end

    def apply_category_conditions(query, categories)
      return query if categories.blank?

      # The Uncategorized sentinel, or the display name older links still send
      include_uncategorized = categories.any? { |c| Category.uncategorized_filter_value?(c) }
      named_categories = categories.reject { |c| Category.uncategorized_filter_value?(c) }

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
        # The legs of a transfer between own accounts have nothing to categorize
        conditions << "(categories.id IS NULL AND transactions.kind NOT IN (?))"
        binds.push(Transaction::UNCATEGORIZED_EXCLUDED_KINDS)
      end

      return query if conditions.empty?
      query.where(conditions.join(" OR "), *binds)
    end

    # Merchant names, plus the "No merchant" sentinel for transactions without one
    def apply_merchant_conditions(query, merchants)
      return query if merchants.blank?

      include_no_merchant = merchants.include?(Merchant::NO_MERCHANT_FILTER_VALUE)
      named = merchants - [ Merchant::NO_MERCHANT_FILTER_VALUE ]
      query = query.joins(TRANSACTIONS_JOIN)

      if include_no_merchant
        query
          .joins("LEFT JOIN merchants ON merchants.id = transactions.merchant_id")
          .where("merchants.name IN (?) OR transactions.merchant_id IS NULL", named)
      else
        query
          .joins("INNER JOIN merchants ON merchants.id = transactions.merchant_id")
          .where(merchants: { name: named })
      end
    end

    # Tag names, plus the "Untagged" sentinel for transactions without a tag. Subqueries,
    # not a join, so an entry with two of the filtered tags is one row.
    def apply_tag_conditions(query, tags)
      return query if tags.blank?

      include_untagged = tags.include?(Tag::UNTAGGED_FILTER_VALUE)
      named = tags - [ Tag::UNTAGGED_FILTER_VALUE ]
      entries = Entry.arel_table

      tagged = entries[:entryable_id].in(self.class.tagged_transaction_ids(named).arel) if named.any?
      untagged = self.class.untagged_condition(entries[:entryable_id]) if include_untagged

      query.where(entryable_type: "Transaction").where([ tagged, untagged ].compact.reduce(:or))
    end

    # With or without a file. Only a transaction takes files, so either value leaves
    # balance updates and trades out, as the Untagged option does.
    def apply_attachment_conditions(query, statuses)
      wanted = Array(statuses) & Transaction::Search::ATTACHMENT_STATUSES
      return query unless wanted.one?

      attached = self.class.attachment_condition(Entry.arel_table[:entryable_id])
      query.where(entryable_type: "Transaction").where(wanted == [ "with" ] ? attached : attached.not)
    end

    def build_transaction_type_condition(txn_types)
      return if txn_types.blank?

      entries = Entry.arel_table
      is_transaction = entries[:entryable_type].eq("Transaction")
      transfer, expense, income = Transaction.type_conditions(
        transfer: transaction_kind_condition(Transaction::TRANSFER_KINDS),
        investment_contribution: transaction_kind_condition([ "investment_contribution" ])
      ).values_at(:transfer, :expense, :income)

      case txn_types.sort
      when %w[expense income transfer]
        is_transaction
      when [ "transfer" ]
        transfer
      when [ "expense" ]
        is_transaction.and(expense).and(transfer.not)
      when [ "income" ]
        is_transaction.and(income).and(transfer.not)
      when %w[expense transfer]
        is_transaction.and(expense.or(transfer))
      when %w[income transfer]
        is_transaction.and(income.or(transfer))
      when %w[expense income]
        is_transaction.and(transfer.not)
      end
    end

    # The entry is a transaction of one of the kinds. A subquery, because this search does
    # not always join transactions.
    def transaction_kind_condition(kinds)
      entries = Entry.arel_table

      Transaction
        .where(kind: kinds)
        .where(Transaction.arel_table[:id].eq(entries[:entryable_id]))
        .where(entries[:entryable_type].eq("Transaction"))
        .select(1)
        .arel
        .exists
    end
end
