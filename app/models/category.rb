class Category < ApplicationRecord
  has_many :transactions, dependent: :nullify, class_name: "Transaction"
  has_many :import_mappings, as: :mappable, dependent: :destroy, class_name: "Import::Mapping"

  belongs_to :family

  has_many :budget_categories, dependent: :destroy
  has_many :subcategories, class_name: "Category", foreign_key: :parent_id, dependent: :nullify
  belongs_to :parent, class_name: "Category", optional: true

  validates :name, :color, :lucide_icon, :family, presence: true
  validates :name, uniqueness: { scope: :family_id }

  validate :category_level_limit
  validate :nested_category_matches_parent_classification

  before_save :inherit_color_from_parent

  scope :alphabetically, -> { order(:name) }
  scope :alphabetically_by_hierarchy, -> {
    left_joins(:parent)
      .order(Arel.sql("COALESCE(parents_categories.name, categories.name)"))
      .order(Arel.sql("parents_categories.name IS NOT NULL"))
      .order(:name)
  }
  scope :roots, -> { where(parent_id: nil) }
  scope :incomes, -> { where(classification: "income") }
  scope :expenses, -> { where(classification: "expense") }

  COLORS = %w[#e99537 #4da568 #6471eb #db5a54 #df4e92 #c44fe9 #eb5429 #61c9ea #805dee #6ad28a]

  UNCATEGORIZED_COLOR = "#737373"
  OTHER_INVESTMENTS_COLOR = "#e99537"
  TRANSFER_COLOR = "#444CE7"
  PAYMENT_COLOR = "#db5a54"
  TRADE_COLOR = "#e99537"

  # Category name keys for i18n
  UNCATEGORIZED_NAME_KEY = "models.category.uncategorized"
  OTHER_INVESTMENTS_NAME_KEY = "models.category.other_investments"
  INVESTMENT_CONTRIBUTIONS_NAME_KEY = "models.category.investment_contributions"

  class Group
    attr_reader :category, :subcategories

    delegate :name, :color, :id, to: :category

    def self.for(categories)
      categories
        .select { |category| category.parent_id.nil? }
        .sort_by { |category| category.name.downcase }
        .map do |category|
          new(category, category.subcategories.alphabetically)
        end
    end

    def initialize(category, subcategories = nil)
      @category = category
      @subcategories = subcategories || []
    end

    def to_grouped_options
      [ name, category_and_subcategory_options ]
    end

    private
      def category_and_subcategory_options
        [ [ name, id ] ].tap do |options|
          sorted_subcategories.each do |subcategory|
            options << [ subcategory.name, subcategory.id ]
          end
        end
      end

      def sorted_subcategories
        Array(subcategories).sort_by { |subcategory| subcategory.name.downcase }
      end
  end

  class << self
    def grouped_select_options(categories)
      Category::Group.for(Array(categories)).map(&:to_grouped_options)
    end

    def icon_codes
      %w[
        apple award baby banknote scan bar-chart bath
        battery beer bike bluetooth bone book book-open briefcase building bus
        cake calculator calendar camera car
        dollar-sign coffee coins compass cookie
        credit-card dices droplet film flame flower
        fuel gem gift glasses globe graduation-cap hammer
        headphones heart home
        key landmark laptop leaf lightbulb luggage mail map-pin
        mic monitor moon music package palette pencil
        percent phone pie-chart pizza plane plug power printer
        puzzle scale scissors settings shield
        shirt shopping-bag shopping-cart smartphone
        stethoscope sun tag target tent thermometer ticket train
        trending-up trophy truck tv umbrella undo-2 users utensils
        video wallet waves wifi wine wrench zap layers
      ]
    end

    def bootstrap!
      default_categories.each do |name, color, icon, classification|
        find_or_create_by!(name: name) do |category|
          category.color = color
          category.classification = classification
          category.lucide_icon = icon
        end
      end
    end

    def uncategorized
      new(
        name: I18n.t(UNCATEGORIZED_NAME_KEY),
        color: UNCATEGORIZED_COLOR,
        lucide_icon: "circle-dot"
      )
    end

    def other_investments
      new(
        name: I18n.t(OTHER_INVESTMENTS_NAME_KEY),
        color: OTHER_INVESTMENTS_COLOR,
        lucide_icon: "trending-up"
      )
    end

    # Helper to get the localized name for uncategorized
    def uncategorized_name
      I18n.t(UNCATEGORIZED_NAME_KEY)
    end

    # Helper to get the localized name for other investments
    def other_investments_name
      I18n.t(OTHER_INVESTMENTS_NAME_KEY)
    end

    # Helper to get the localized name for investment contributions
    def investment_contributions_name
      I18n.t(INVESTMENT_CONTRIBUTIONS_NAME_KEY)
    end

    private
      def default_categories
        [
          [ "Income", "#22c55e", "dollar-sign", "income" ],
          [ "Food & Drink", "#f97316", "utensils", "expense" ],
          [ "Groceries", "#407706", "shopping-bag", "expense" ],
          [ "Shopping", "#3b82f6", "shopping-cart", "expense" ],
          [ "Transportation", "#0ea5e9", "bus", "expense" ],
          [ "Travel", "#2563eb", "plane", "expense" ],
          [ "Entertainment", "#a855f7", "film", "expense" ],
          [ "Healthcare", "#4da568", "stethoscope", "expense" ],
          [ "Personal Care", "#14b8a6", "scissors", "expense" ],
          [ "Home Improvement", "#d97706", "hammer", "expense" ],
          [ "Mortgage / Rent", "#b45309", "home", "expense" ],
          [ "Utilities", "#eab308", "lightbulb", "expense" ],
          [ "Subscriptions", "#6366f1", "wifi", "expense" ],
          [ "Insurance", "#0284c7", "shield", "expense" ],
          [ "Sports & Fitness", "#10b981", "target", "expense" ],
          [ "Gifts & Donations", "#61c9ea", "gift", "expense" ],
          [ "Taxes", "#dc2626", "landmark", "expense" ],
          [ "Loan Payments", "#e11d48", "credit-card", "expense" ],
          [ "Services", "#7c3aed", "briefcase", "expense" ],
          [ "Fees", "#6b7280", "file-text", "expense" ],
          [ "Savings & Investments", "#059669", "trending-up", "expense" ],
          [ investment_contributions_name, "#0d9488", "trending-up", "expense" ]
        ]
      end
  end

  def inherit_color_from_parent
    if subcategory?
      self.color = parent.color
    end
  end

  def replace_and_destroy!(replacement)
    transaction do
      transactions.update_all category_id: replacement&.id
      destroy!
    end
  end

  def parent?
    subcategories.any?
  end

  def subcategory?
    parent.present?
  end

  def name_with_parent
    subcategory? ? "#{parent.name} > #{name}" : name
  end

  # Predicate: is this the synthetic "Uncategorized" category?
  def uncategorized?
    !persisted? && name == I18n.t(UNCATEGORIZED_NAME_KEY)
  end

  # Predicate: is this the synthetic "Other Investments" category?
  def other_investments?
    !persisted? && name == I18n.t(OTHER_INVESTMENTS_NAME_KEY)
  end

  # Predicate: is this any synthetic (non-persisted) category?
  def synthetic?
    uncategorized? || other_investments?
  end

  private
    def category_level_limit
      if (subcategory? && parent.subcategory?) || (parent? && subcategory?)
        errors.add(:parent, "can't have more than 2 levels of subcategories")
      end
    end

    def nested_category_matches_parent_classification
      if subcategory? && parent.classification != classification
        errors.add(:parent, "must have the same classification as its parent")
      end
    end

    def monetizable_currency
      family.currency
    end
end
