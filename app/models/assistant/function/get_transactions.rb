class Assistant::Function::GetTransactions < Assistant::Function
  include Paginatable

  class << self
    def default_page_size
      50
    end

    def name
      "get_transactions"
    end

    def description
      <<~INSTRUCTIONS
        Use this to search user's transactions by using various optional filters.

        This function is great for things like:
        - Finding specific transactions
        - Getting basic stats about a small group of transactions

        This function is not great for:
        - Large time periods (use the get_income_statement function for this)

        Filters take exact names: use the values returned by get_accounts,
        get_categories, get_merchants and get_tags when unsure. Pass
        types: ["income", "expense"] to leave out transfers between the user's
        own accounts. Use a small page_size when you only need a few rows.

        Reading a row:

        - `amount` is always POSITIVE. `direction` says whether money came in
          ("inflow") or went out ("outflow").
        - `classification` is "income", "expense" or "transfer". A transfer is
          money moving between the user's own accounts: it is neither income
          nor spending. Never add transfer rows to income or expense sums.
        - A transfer shows up as ONE row, its outflow leg, with
          `transfer_account` naming the account the money went to. Its inflow
          leg is listed only when the filters leave the outflow leg out (for
          example an accounts filter on the receiving account); there
          `transfer_account` names the account the money came from.
        - `kind` is the stored kind: "standard", "funds_movement",
          "cc_payment", "loan_payment", "investment_contribution" or
          "one_time". A loan payment is a transfer that the budget still
          counts as an expense; an investment contribution is an expense.
        - `name` is the transaction's description as the user sees it.
        - `category`, `merchant`, `tags` and `notes` appear only when set;
          `pending` and `excluded` appear only when true. An absent key means
          none or false.
        - A split transaction (one bank line the user divided by purpose) is
          listed as its parts. Each part has `split_of` (the entry_id of the
          whole transaction) and counts as its own income or expense; the
          whole transaction is not listed, so never add it to the parts.
        - `account_excluded_from_reports` (only when true): the row's account is
          one the user keeps out of every report. The row is listed, as on the
          transactions page, but dashboards and get_income_statement never
          count it.

        `total_income` and `total_expenses` are computed over the whole
        filtered set the way the dashboard counts them (transfers and excluded
        rows left out), so they do not always equal the sum of this page. Like
        the transactions page, they do count accounts excluded from reports;
        filter those accounts out to match the dashboard.

        Note on pagination:

        This function can be paginated.  You can expect the following properties in the response:

        - `total_pages`: The total number of pages of results
        - `page`: The current page of results
        - `page_size`: The number of results per page (defaults to #{default_page_size})
        - `total_results`: The total number of rows for the given filters
        - `total_income`: The total income for the given filters
        - `total_expenses`: The total expenses for the given filters

        Example (last 30 days, no transfers):

        ```
        get_transactions({
          start_date: "#{30.days.ago.to_date}",
          end_date: "#{Date.current}",
          types: ["income", "expense"]
        })
        ```
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        page: {
          type: "integer",
          minimum: 1,
          description: "Page number (defaults to 1)"
        },
        page_size: {
          type: "integer",
          minimum: 1,
          maximum: MAX_PAGE_SIZE,
          description: "Results per page (defaults to #{self.class.default_page_size}); use small values to save tokens"
        },
        order: {
          type: "string",
          enum: [ "asc", "desc" ],
          description: "Sort direction (defaults to desc)"
        },
        sort_by: {
          type: "string",
          enum: [ "date", "amount" ],
          description: "Sort by date (default) or by absolute amount"
        },
        search: {
          type: "string",
          description: "Search for transactions by name"
        },
        amount: {
          type: "string",
          description: "Amount for transactions (must be used with amount_operator)"
        },
        amount_operator: {
          type: "string",
          description: "Operator for amount (must be used with amount)",
          enum: [ "equal", "less", "greater" ]
        },
        start_date: {
          type: "string",
          description: "Start date for transactions in YYYY-MM-DD format"
        },
        end_date: {
          type: "string",
          description: "End date for transactions in YYYY-MM-DD format"
        },
        types: {
          type: "array",
          description: "Filter by classification; [\"income\", \"expense\"] leaves out transfers between the user's own accounts",
          items: { type: "string", enum: [ "income", "expense", "transfer" ] },
          minItems: 1,
          uniqueItems: true
        },
        statuses: {
          type: "array",
          description: "Filter by status",
          items: { type: "string", enum: [ "pending", "confirmed" ] },
          minItems: 1,
          uniqueItems: true
        },
        account_ids: {
          type: "array",
          description: "Filter by account UUIDs as returned by get_accounts",
          items: { type: "string" },
          minItems: 1,
          uniqueItems: true
        },
        accounts: {
          type: "array",
          description: "Filter by exact account names as returned by get_accounts",
          items: { type: "string" },
          minItems: 1,
          uniqueItems: true
        },
        categories: {
          type: "array",
          description: "Filter by exact category names as returned by get_categories (\"Uncategorized\" is accepted); a parent category includes its subcategories",
          items: { type: "string" },
          minItems: 1,
          uniqueItems: true
        },
        merchants: {
          type: "array",
          description: "Filter by exact merchant names as returned by get_merchants",
          items: { type: "string" },
          minItems: 1,
          uniqueItems: true
        },
        tags: {
          type: "array",
          description: "Filter by exact tag names as returned by get_tags",
          items: { type: "string" },
          minItems: 1,
          uniqueItems: true
        }
      }
    )
  end

  SEARCH_FILTERS = %w[search amount amount_operator start_date end_date types accounts account_ids categories merchants tags].freeze

  def call(params = {})
    search = Transaction::Search.new(family, filters: search_filters(params))
    matching = search.transactions_scope

    page_size = resolved_page_size(params)
    pagy, transactions = pagy(
      ordered(one_row_per_transfer(matching), params).includes(
        { entry: :account },
        :category, :merchant, :tags,
        transfer_as_outflow: { inflow_transaction: { entry: :account } },
        transfer_as_inflow: { outflow_transaction: { entry: :account } }
      ),
      page: resolved_page(params),
      limit: page_size,
      request: { params: {} }
    )

    totals = search.totals

    {
      transactions: transactions.map { |txn| row_for(txn) },
      total_results: pagy.count,
      page: pagy.page,
      page_size: page_size,
      total_pages: pagy.pages,
      total_income: totals.income_money.format,
      total_expenses: totals.expense_money.format
    }
  end

  private
    def search_filters(params)
      filters = params.slice(*SEARCH_FILTERS)
      filters["status"] = params["statuses"] if params["statuses"].present?

      # An id that is not a UUID would make Postgres raise; it cannot match an account anyway. When no id is
      # valid, a fresh UUID keeps the filter in place so the result is empty, not unfiltered.
      if filters.key?("account_ids")
        valid_ids = Array(filters["account_ids"]).select { |id| valid_uuid?(id) }
        filters["account_ids"] = valid_ids.presence || [ SecureRandom.uuid ]
      end

      filters
    end

    # Both legs of a transfer are transactions, so a plain listing shows the same money twice (once out, once
    # in), and a model summing rows counts it twice. A transfer is listed once, as its outflow leg; its inflow
    # leg stays only when the filters leave the outflow leg out.
    def one_row_per_transfer(scope)
      matching_ids = scope.reselect(:id)
      duplicate_inflow_ids = Transfer.where(outflow_transaction_id: matching_ids).select(:inflow_transaction_id)

      scope.where.not(id: duplicate_inflow_ids)
    end

    def ordered(query, params)
      if params["sort_by"] == "amount"
        # Fully literal order strings; nothing from the caller reaches Arel.sql
        if params["order"] == "asc"
          query.order(Arel.sql("ABS(entries.amount) ASC"), Arel.sql("entries.date DESC"))
        else
          query.order(Arel.sql("ABS(entries.amount) DESC"), Arel.sql("entries.date DESC"))
        end
      else
        params["order"] == "asc" ? query.chronological : query.reverse_chronological
      end
    end

    # Compact by design: keys that are empty or false on most rows are left out, and the description says an
    # absent key means none or false.
    def row_for(txn)
      entry = txn.entry
      counterparty = transfer_counterparty_account(txn)

      row = {
        id: txn.id,
        entry_id: entry.id,
        date: entry.date,
        name: entry.name,
        amount: entry.amount.abs.to_f,
        currency: entry.currency,
        formatted_amount: entry.amount_money.abs.format,
        direction: entry.amount.negative? ? "inflow" : "outflow",
        classification: classification_for(txn, entry),
        kind: txn.kind,
        account: entry.account.name,
        transfer_account: counterparty&.name,
        category: txn.category&.name,
        merchant: txn.merchant&.name,
        notes: entry.notes.presence
      }.compact

      row[:tags] = txn.tags.map(&:name) if txn.tags.any?
      row[:is_transfer] = true if row[:classification] == "transfer"
      row[:pending] = true if txn.pending?
      row[:excluded] = true if entry.excluded?
      row[:split_of] = entry.parent_entry_id if entry.split_child?
      row[:account_excluded_from_reports] = true if entry.account.exclude_from_reports?
      row
    end

    # Same rule as the types filter and the totals: the transfer kinds are transfers (Transfer sets them on both
    # legs), an investment contribution is always an expense, anything else goes by its sign.
    def classification_for(txn, entry)
      if txn.transfer?
        "transfer"
      elsif txn.investment_contribution? || !entry.amount.negative?
        "expense"
      else
        "income"
      end
    end

    # The transfer pair is preloaded for both directions (see the includes above), so naming the other side costs
    # no extra query
    def transfer_counterparty_account(txn)
      if (transfer = txn.transfer_as_outflow)
        transfer.inflow_transaction&.entry&.account
      elsif (transfer = txn.transfer_as_inflow)
        transfer.outflow_transaction&.entry&.account
      end
    end
end
