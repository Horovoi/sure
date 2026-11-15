class Assistant::Function::GetCategories < Assistant::Function
  include Paginatable

  class << self
    def default_page_size
      50
    end

    def name
      "get_categories"
    end

    def description
      <<~INSTRUCTIONS
        Returns the family's categories, ordered alphabetically by hierarchy, with pagination.

        Each entry includes id, name, color, icon, parent_id (absent for top-level),
        and name_with_parent (e.g. "Food & Drink > Restaurants"). The exact names
        work in get_transactions' categories filter; the ids are what tools that
        change a category or a transaction's category take.

        Note on pagination:

        This function can be paginated. You can expect the following properties in the response:

        - `total_pages`: The total number of pages of results
        - `page`: The current page of results
        - `page_size`: The number of results per page (defaults to #{default_page_size})
        - `total_results`: The total number of results
      INSTRUCTIONS
    end
  end

  # Optional params are incompatible with strict function calling, which requires every declared property to be
  # listed in required
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
        }
      }
    )
  end

  def call(params = {})
    page_size = resolved_page_size(params)
    pagy, categories = pagy(
      family.categories.alphabetically_by_hierarchy.preload(:parent),
      page: resolved_page(params),
      limit: page_size,
      request: { params: {} }
    )

    {
      categories: categories.map { |category|
        {
          id: category.id,
          name: category.name,
          name_with_parent: category.name_with_parent,
          color: category.color,
          icon: category.lucide_icon,
          parent_id: category.parent_id,
          is_subcategory: category.subcategory?
        }.compact
      },
      total_results: pagy.count,
      page: pagy.page,
      page_size: page_size,
      total_pages: pagy.pages
    }
  end
end
