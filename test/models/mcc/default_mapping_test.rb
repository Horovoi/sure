require "test_helper"

class Mcc::DefaultMappingTest < ActiveSupport::TestCase
  # The owner's own English category names (custom, not Sure's defaults)
  OWNER_EXPENSES = [
    "Groceries", "Eating Out", "Coffee Out", "Food & Drinks", "Taxi", "Public Transport", "Pharmacies",
    "Streaming", "Subscription Services", "Mobile Plan", "P2P Outgoing", "Fees", "Health", "Medical Services",
    "Shopping", "Clothing", "Electronics", "Utilities", "Rent", "Travel", "Railways", "Gym", "Sports", "Charity",
    "Military"
  ].freeze
  OWNER_INCOMES = [ "P2P Incoming", "Salary", "Interest", "Refund" ].freeze

  def categories(expenses: [], incomes: [])
    expenses.map { |name| Category.new(id: SecureRandom.uuid, name: name, classification: "expense") } +
      incomes.map { |name| Category.new(id: SecureRandom.uuid, name: name, classification: "income") }
  end

  def mapped_name(mapping, key)
    mapping.category_for(key)&.name
  end

  test "normalizes case, punctuation, conjunctions, plurals and Ukrainian endings" do
    normalize = ->(name) { Mcc::DefaultMapping.normalize(name) }

    assert_equal normalize.("food and drinks"), normalize.("Food & Drinks")
    assert_equal normalize.("food drink"), normalize.("Food & Drinks")
    assert_equal normalize.("pharmacy"), normalize.("Pharmacies")
    assert_equal normalize.("mortgage rent"), normalize.("Mortgage / Rent")
    assert_equal normalize.("p2p incoming"), normalize.("P2P  Incoming")
    assert_equal normalize.("кафе і ресторани"), normalize.("Кафе та ресторани")
    assert_equal normalize.("аптека"), normalize.("Аптеки")
    assert_equal normalize.("кав'ярня"), normalize.("Кавʼярні")
    assert_equal normalize.("мобільний зв'язок"), normalize.("Мобільний звʼязок")
    assert_equal normalize.("продукти"), normalize.("ПРОДУКТИ")
  end

  test "maps every group to the owner's English categories" do
    mapping = Mcc::DefaultMapping.new(categories(expenses: OWNER_EXPENSES, incomes: OWNER_INCOMES))

    {
      groceries: "Groceries", eating_out: "Eating Out", coffee: "Coffee Out", fast_food: "Eating Out",
      food_and_drinks: "Food & Drinks", taxi: "Taxi", public_transport: "Public Transport", railways: "Railways",
      travel_air: "Travel", lodging: "Travel", car_rental: "Travel", travel: "Travel", pharmacy: "Pharmacies",
      medical_services: "Medical Services", streaming: "Streaming", digital_subscriptions: "Subscription Services",
      mobile_plan: "Mobile Plan", internet: "Utilities", utilities: "Utilities", rent: "Rent", gym: "Gym",
      sports: "Sports", clothing: "Clothing", electronics: "Electronics", home: "Shopping", beauty: "Shopping",
      pets: "Shopping", kids: "Shopping", books: "Shopping", shopping: "Shopping", charity: "Charity",
      military_support: "Military", bank_fees: "Fees", interest: "Interest", salary: "Salary", refund: "Refund",
      p2p_incoming: "P2P Incoming", p2p_outgoing: "P2P Outgoing"
    }.each do |key, name|
      assert_equal name, mapped_name(mapping, key), "group #{key}"
    end
  end

  test "leaves groups without a matching owner category uncategorised" do
    mapping = Mcc::DefaultMapping.new(categories(expenses: OWNER_EXPENSES, incomes: OWNER_INCOMES))

    %i[fuel parking car_service education entertainment delivery services taxes government_fees insurance cashback].each do |key|
      assert_nil mapped_name(mapping, key), "group #{key}"
    end
  end

  test "maps Ukrainian-named categories" do
    mapping = Mcc::DefaultMapping.new(categories(
      expenses: [ "Продукти", "Кафе та ресторани", "Таксі", "Аптеки", "Комуналка", "Мобільний звʼязок", "Донати на ЗСУ" ],
      incomes: [ "Зарплата", "Кешбек", "Повернення" ]
    ))

    assert_equal "Продукти", mapped_name(mapping, :groceries)
    assert_equal "Кафе та ресторани", mapped_name(mapping, :eating_out)
    assert_equal "Кафе та ресторани", mapped_name(mapping, :coffee)
    assert_equal "Кафе та ресторани", mapped_name(mapping, :fast_food)
    assert_equal "Таксі", mapped_name(mapping, :taxi)
    assert_equal "Аптеки", mapped_name(mapping, :pharmacy)
    assert_equal "Комуналка", mapped_name(mapping, :utilities)
    assert_equal "Комуналка", mapped_name(mapping, :internet)
    assert_equal "Мобільний звʼязок", mapped_name(mapping, :mobile_plan)
    assert_equal "Донати на ЗСУ", mapped_name(mapping, :military_support)
    assert_equal "Зарплата", mapped_name(mapping, :salary)
    assert_equal "Кешбек", mapped_name(mapping, :cashback)
    assert_equal "Повернення", mapped_name(mapping, :refund)
  end

  test "maps Sure's default English categories" do
    mapping = Mcc::DefaultMapping.new(categories(
      expenses: [ "Food & Drink", "Groceries", "Shopping", "Transportation", "Travel", "Entertainment", "Healthcare",
                  "Personal Care", "Home Improvement", "Mortgage / Rent", "Utilities", "Subscriptions", "Insurance",
                  "Sports & Fitness", "Gifts & Donations", "Taxes", "Services", "Fees" ],
      incomes: [ "Income" ]
    ))

    assert_equal "Food & Drink", mapped_name(mapping, :eating_out)
    assert_equal "Food & Drink", mapped_name(mapping, :coffee)
    assert_equal "Groceries", mapped_name(mapping, :groceries)
    assert_equal "Transportation", mapped_name(mapping, :taxi)
    assert_equal "Transportation", mapped_name(mapping, :fuel)
    assert_equal "Travel", mapped_name(mapping, :railways)
    assert_equal "Healthcare", mapped_name(mapping, :pharmacy)
    assert_equal "Personal Care", mapped_name(mapping, :beauty)
    assert_equal "Home Improvement", mapped_name(mapping, :home)
    assert_equal "Mortgage / Rent", mapped_name(mapping, :rent)
    assert_equal "Subscriptions", mapped_name(mapping, :digital_subscriptions)
    assert_equal "Subscriptions", mapped_name(mapping, :streaming)
    assert_equal "Sports & Fitness", mapped_name(mapping, :gym)
    assert_equal "Gifts & Donations", mapped_name(mapping, :charity)
    assert_equal "Gifts & Donations", mapped_name(mapping, :military_support)
    assert_equal "Taxes", mapped_name(mapping, :government_fees)
    assert_equal "Services", mapped_name(mapping, :delivery)
    assert_equal "Income", mapped_name(mapping, :salary)
    assert_equal "Income", mapped_name(mapping, :interest)
  end

  test "spending groups only match expense categories and income groups only income ones" do
    mapping = Mcc::DefaultMapping.new(categories(expenses: [ "Salary" ], incomes: [ "Groceries", "Taxi" ]))

    assert_nil mapped_name(mapping, :groceries)
    assert_nil mapped_name(mapping, :taxi)
    assert_nil mapped_name(mapping, :salary)
  end

  test "a refund matches an expense or an income category" do
    assert_equal "Refund", mapped_name(Mcc::DefaultMapping.new(categories(expenses: [ "Refund" ])), :refund)
    assert_equal "Refunds", mapped_name(Mcc::DefaultMapping.new(categories(incomes: [ "Refunds" ])), :refund)
  end

  test "the first alias wins when several categories match" do
    mapping = Mcc::DefaultMapping.new(categories(expenses: [ "Subscriptions", "Subscription Services" ]))

    assert_equal "Subscription Services", mapped_name(mapping, :digital_subscriptions)
  end

  test "a top-level category wins over a subcategory with the same normalized name" do
    parent = Category.new(id: SecureRandom.uuid, name: "Living", classification: "expense")
    sub = Category.new(id: SecureRandom.uuid, name: "Food and Drink", classification: "expense", parent_id: parent.id)
    root = Category.new(id: SecureRandom.uuid, name: "Food & Drink", classification: "expense")

    assert_equal root, Mcc::DefaultMapping.new([ sub, parent, root ]).category_for(:eating_out)
  end

  test "matches subcategories" do
    parent = Category.new(id: SecureRandom.uuid, name: "Subscriptions", classification: "expense")
    sub = Category.new(id: SecureRandom.uuid, name: "Streaming", classification: "expense", parent_id: parent.id)
    mapping = Mcc::DefaultMapping.new([ parent, sub ])

    assert_equal sub, mapping.category_for(:streaming)
    assert_equal parent, mapping.category_for(:digital_subscriptions)
  end

  test "skipped and fallback-only groups get nothing" do
    mapping = Mcc::DefaultMapping.new(categories(
      expenses: [ "Cash", "Gambling", "Own Transfers", "Health" ], incomes: [ "Income" ]
    ))

    assert_nil mapped_name(mapping, :cash_withdrawal)
    assert_nil mapped_name(mapping, :gambling)
    assert_nil mapped_name(mapping, :own_transfer)
    assert_nil mapped_name(mapping, :health)
    assert_nil mapped_name(mapping, :income)
    assert_nil mapped_name(mapping, :unknown)
  end

  test "no categories, no match" do
    assert_nil Mcc::DefaultMapping.new([]).category_for(:groceries)
  end
end
