class Category < ApplicationRecord
  has_many :transactions, dependent: :nullify, class_name: "Transaction"
  has_many :import_mappings, as: :mappable, dependent: :destroy, class_name: "Import::Mapping"

  belongs_to :family

  has_many :budget_categories, dependent: :destroy
  has_many :subcategories, class_name: "Category", foreign_key: :parent_id, dependent: :nullify
  belongs_to :parent, class_name: "Category", optional: true

  validates :name, :color, :lucide_icon, :family, presence: true
  # Checked only when the colour changes, so an old row with another colour can still be renamed
  validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }, if: :will_save_change_to_color?
  validates :name, uniqueness: { scope: :family_id }
  # "Income" from a CSV import or an API caller means income; anything else is rejected,
  # since a category that is neither shows up in no income or expense list.
  normalizes :classification, with: ->(value) { value.to_s.strip.downcase }
  validates :classification, inclusion: { in: %w[income expense] }

  validate :category_level_limit
  validate :nested_category_matches_parent_classification
  validate :parent_in_same_family

  before_validation :inherit_classification_from_parent, on: :create
  before_save :inherit_color_from_parent
  after_update :propagate_color_to_subcategories, if: :saved_change_to_color?

  scope :alphabetically, -> { order(:name) }
  scope :recently_used, -> { where.not(last_used_at: nil).order(last_used_at: :desc) }
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
      roots = categories
        .select { |category| category.parent_id.nil? }
        .sort_by { |category| category.name.downcase }

      # One ordered query for every group's subcategories, instead of one per group
      root_ids = roots.filter_map(&:id)
      subcategories_by_parent = if root_ids.any?
        Category.where(parent_id: root_ids).alphabetically.group_by(&:parent_id)
      else
        {}
      end

      roots.map { |category| new(category, subcategories_by_parent.fetch(category.id, [])) }
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

    # Categories a family has assigned by hand recently: a shortcut above the
    # alphabetical list in the pickers, not a replacement for it. See
    # Transaction#record_category_usage! for where last_used_at is written.
    # Pass classification to keep only the categories the form can use.
    def recently_used_for(family:, excluding: [], limit: 4, classification: nil)
      scope = family.categories.recently_used.where.not(id: Array(excluding).compact.map(&:id))
      scope = scope.where(classification: classification) if classification.present?
      scope.limit(limit)
    end

    # The icons the category form offers. The first block is upstream's list.
    # The second keeps the icons that an earlier version of this app gave to
    # categories (its shorter list and its icon rename), so that every
    # category that exists today still shows its icon as selected.
    def icon_codes
      %w[
        ambulance apple award baby badge-dollar-sign banknote barcode bar-chart-3 bath
        battery bed-single beer bike bluetooth bone book book-open briefcase building bus
        cake calculator calendar-heart calendar-range camera car cat chart-line
        circle-dollar-sign circle-parking coffee coins compass cookie cooking-pot
        credit-card dices dog drama drill droplet drum dumbbell film flame flower flower-2
        fuel gamepad-2 gem gift glasses globe graduation-cap hammer hand-heart
        hand-helping heart-handshake handshake headphones heart heart-pulse home hotel
        house ice-cream-cone key landmark laptop leaf lightbulb luggage mail map-pin
        martini mic monitor moon music package palette party-popper paw-print pen pencil
        percent phone pie-chart piggy-bank pill pizza plane plug popcorn power printer
        puzzle receipt receipt-text ribbon scale scissors settings shield shield-plus
        shirt shopping-bag shopping-basket shopping-cart smartphone sparkles sprout
        stethoscope store sun tablet-smartphone tag target tent thermometer ticket train
        trees tree-palm trending-up trophy truck tv umbrella undo-2 unplug users utensils
        video wallet wallet-cards waves wifi wine wrench zap
        bar-chart calendar dollar-sign file-text layers scan shapes star
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
        lucide_icon: "circle-dashed"
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
          [ "Income", "#22c55e", "circle-dollar-sign", "income" ],
          [ "Food & Drink", "#f97316", "utensils", "expense" ],
          [ "Groceries", "#407706", "shopping-bag", "expense" ],
          [ "Shopping", "#3b82f6", "shopping-cart", "expense" ],
          [ "Transportation", "#0ea5e9", "bus", "expense" ],
          [ "Travel", "#2563eb", "plane", "expense" ],
          [ "Entertainment", "#a855f7", "drama", "expense" ],
          [ "Healthcare", "#4da568", "pill", "expense" ],
          [ "Personal Care", "#14b8a6", "scissors", "expense" ],
          [ "Home Improvement", "#d97706", "hammer", "expense" ],
          [ "Mortgage / Rent", "#b45309", "home", "expense" ],
          [ "Utilities", "#eab308", "lightbulb", "expense" ],
          [ "Subscriptions", "#6366f1", "wifi", "expense" ],
          [ "Insurance", "#0284c7", "shield", "expense" ],
          [ "Sports & Fitness", "#10b981", "dumbbell", "expense" ],
          [ "Gifts & Donations", "#61c9ea", "hand-helping", "expense" ],
          [ "Taxes", "#dc2626", "landmark", "expense" ],
          [ "Loan Payments", "#e11d48", "credit-card", "expense" ],
          [ "Services", "#7c3aed", "briefcase", "expense" ],
          [ "Fees", "#6b7280", "receipt", "expense" ],
          [ "Savings & Investments", "#059669", "piggy-bank", "expense" ],
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

  # The key that groups income statement category totals. Both synthetic categories
  # have no id, so keying by id alone puts Uncategorized and Other investments on the
  # same nil key and one overwrites the other. Budget and the category netting of the
  # income statement both index totals by this one key.
  def totals_key
    return :uncategorized if uncategorized?
    return :other_investments if other_investments?

    id
  end

  private
    # Subcategories take their parent's colour only when they are saved, so push a
    # parent's new colour to the existing ones.
    def propagate_color_to_subcategories
      subcategories.update_all(color: color, updated_at: Time.current)
    end

    # A new subcategory always takes its parent's classification, whatever the
    # form sent: an inline create from an income transaction can't put an
    # expense parent's child into income.
    def inherit_classification_from_parent
      self.classification = parent.classification if parent.present?
    end

    def parent_in_same_family
      if parent.present? && parent.family_id != family_id
        errors.add(:parent, :invalid)
      end
    end

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
