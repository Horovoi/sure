require "test_helper"

class Transaction::NameSuggestionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @groceries = @family.categories.create!(name: "Name Suggestion Groceries", color: "#407706", lucide_icon: "shopping-bag")
    @dining = @family.categories.create!(name: "Name Suggestion Dining", color: "#f97316", lucide_icon: "utensils")
  end

  test "matches part of a name and ranks the most used names first" do
    2.times { create_transaction(account: @account, name: "Silpo Market") }
    create_transaction(account: @account, name: "Silpo Express")

    names = suggest("silpo").map(&:name)

    assert_equal [ "Silpo Market", "Silpo Express" ], names
  end

  test "a short query matches the start of the name only" do
    create_transaction(account: @account, name: "ATB shop")
    create_transaction(account: @account, name: "Coffee AT home")

    names = suggest("AT").map(&:name)

    assert_includes names, "ATB shop"
    assert_not_includes names, "Coffee AT home"
  end

  test "a blank query lists the most recent names" do
    create_transaction(account: @account, name: "Older name", date: 5.days.ago.to_date)
    create_transaction(account: @account, name: "Newest name", date: Date.current)

    names = suggest("", limit: 1_000).map(&:name)

    assert_operator names.index("Newest name"), :<, names.index("Older name")
  end

  test "pairs each name with the category used most often for it" do
    2.times { create_transaction(account: @account, name: "Novus", category: @groceries) }
    create_transaction(account: @account, name: "Novus", category: @dining)
    create_transaction(account: @account, name: "Novus")

    suggestion = suggest("novus").sole

    assert_equal @groceries, suggestion.category
  end

  test "leaves the category out when the name was never categorized" do
    create_transaction(account: @account, name: "Plain kiosk")

    assert_nil suggest("kiosk").sole.category
  end

  test "suggests only categories of the form's classification" do
    salary = @family.categories.create!(name: "Name Suggestion Salary", color: "#22c55e", lucide_icon: "banknote", classification: "income")
    create_transaction(account: @account, name: "Employer payout", amount: -1000, category: salary)

    assert_nil suggest("payout", classification: "expense").sole.category
    assert_equal salary, suggest("payout", classification: "income").sole.category
  end

  test "reads only the family's own transactions" do
    other_account = families(:empty).accounts.create!(name: "Other", balance: 0, currency: "USD", accountable: Depository.new)
    create_transaction(account: other_account, name: "Secret other family shop")

    assert_empty suggest("secret other")
  end

  test "leaves transfer legs out" do
    entry = create_transaction(account: @account, name: "Transfer to savings box")
    entry.transaction.update_column(:kind, "funds_movement")

    assert_empty suggest("savings box")
  end

  test "escapes LIKE wildcards in the query" do
    create_transaction(account: @account, name: "100% juice")
    create_transaction(account: @account, name: "1000 juice")

    assert_equal [ "100% juice" ], suggest("100%").map(&:name)
  end

  test "returns at most the limit" do
    10.times { |i| create_transaction(account: @account, name: "Limit shop #{i}") }

    assert_equal 8, suggest("limit shop").size
  end

  private
    def suggest(query, classification: nil, limit: Transaction::NameSuggestion::DEFAULT_LIMIT)
      Transaction::NameSuggestion.for(@family, query, classification: classification, limit: limit)
    end
end
