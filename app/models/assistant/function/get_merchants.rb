class Assistant::Function::GetMerchants < Assistant::Function
  include Paginatable

  class << self
    def default_page_size
      50
    end

    def name
      "get_merchants"
    end

    def description
      <<~INSTRUCTIONS
        Returns the merchants on the family's transactions and the family's own
        merchants, sorted alphabetically, with pagination. Each entry includes
        the id that tools changing a transaction's merchant take, and the exact
        name that works in get_transactions' merchants filter.

        Pass `search` to filter by name instead of paging through everything.
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
          description: "Results per page (defaults to #{self.class.default_page_size})"
        },
        search: {
          type: "string",
          description: "Case-insensitive substring filter on merchant name"
        }
      }
    )
  end

  def call(params = {})
    scope = family.available_merchants.alphabetically

    if params["search"].present?
      scope = scope.where("merchants.name ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params["search"].to_s)}%")
    end

    page_size = resolved_page_size(params)
    pagy, merchants = pagy(scope, page: resolved_page(params), limit: page_size, request: { params: {} })

    {
      merchants: merchants.map { |merchant|
        {
          id: merchant.id,
          name: merchant.name,
          # A family merchant was made in Sure; a provider merchant came from merchant detection
          source: merchant.type == "FamilyMerchant" ? "family" : "provider"
        }
      },
      total_results: pagy.count,
      page: pagy.page,
      page_size: page_size,
      total_pages: pagy.pages
    }
  end
end
