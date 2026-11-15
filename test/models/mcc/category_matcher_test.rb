require "test_helper"

class Mcc::CategoryMatcherTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @groceries = create_category("Groceries")
    @eating_out = create_category("Eating Out")
    @taxi = create_category("Taxi")
    @refund = create_category("Refund", classification: "income")
    @p2p_in = create_category("P2P Incoming", classification: "income")
    @p2p_out = create_category("P2P Outgoing")
    @cash = create_category("Cash")
    MccCategoryMapping.where(family: @family).delete_all
  end

  def create_category(name, classification: "expense")
    @family.categories.create!(name: name, classification: classification, color: "#407706", lucide_icon: "tag")
  end

  def matcher
    Mcc::CategoryMatcher.new(@family)
  end

  test "picks the automatic category for a code" do
    assert_equal @groceries, matcher.category_for(mcc: 5411, amount: 120)
    assert_equal @eating_out, matcher.category_for(mcc: 5814, amount: 120)
    assert_equal @taxi, matcher.category_for(mcc: 5999, amount: 120, description: "Uklon")
  end

  test "returns nil for unmapped codes and groups without a category" do
    assert_nil matcher.category_for(mcc: 6012, amount: 120)
    assert_nil matcher.category_for(mcc: 5541, amount: 120)
  end

  test "an inflow at a shop goes to the refund category" do
    assert_equal @refund, matcher.category_for(mcc: 5411, amount: -45)
  end

  test "money transfers follow the direction" do
    assert_equal @p2p_out, matcher.category_for(mcc: 4829, amount: 500, description: "Олена К.")
    assert_equal @p2p_in, matcher.category_for(mcc: 4829, amount: -500, description: "Від: Олена К.")
  end

  test "own transfers never get a category, even with a stored mapping" do
    MccCategoryMapping.create!(family: @family, group_key: "p2p_outgoing", category: @p2p_out)

    assert_nil matcher.category_for(mcc: 4829, amount: 500, description: "Олена К.", own_transfer: true)
    assert_nil matcher.category_for(mcc: 4829, amount: 500, description: "На банку «Відпустка»")
    assert_nil matcher.category_for(mcc: 4829, amount: -500, description: "Купівля валюти")
    assert_equal :own_transfer, matcher.group_for(mcc: 5411, amount: 1, own_transfer: true).key
  end

  test "cash withdrawals get nothing unless the family chose a category" do
    assert_nil matcher.category_for(mcc: 6011, amount: 1_000)

    MccCategoryMapping.create!(family: @family, group_key: "cash_withdrawal", category: @cash)

    assert_equal @cash, matcher.category_for(mcc: 6011, amount: 1_000)
  end

  test "a stored category overrides the automatic one" do
    MccCategoryMapping.create!(family: @family, group_key: "groceries", category: @eating_out)

    assert_equal @eating_out, matcher.category_for(mcc: 5411, amount: 120)
    assert_equal @groceries, matcher.automatic_category_for(:groceries)
  end

  test "a disabled group is not categorised" do
    MccCategoryMapping.create!(family: @family, group_key: "taxi", disabled: true)

    assert_nil matcher.category_for(mcc: 4121, amount: 120)
  end

  test "a group whose chosen category was deleted is automatic again" do
    chosen = create_category("Supermarkets and more")
    MccCategoryMapping.create!(family: @family, group_key: "groceries", category: chosen)
    chosen.destroy!

    assert_nil MccCategoryMapping.find_by(family: @family, group_key: "groceries").category_id
    assert_equal @groceries, matcher.category_for(mcc: 5411, amount: 120)
  end

  test "ignores a stored category of another family" do
    mapping = MccCategoryMapping.create!(family: @family, group_key: "groceries", category: @eating_out)
    mapping.update_column(:category_id, categories(:food_and_drink).id)

    assert_equal @groceries, matcher.category_for(mcc: 5411, amount: 120)
  end

  test "reads mappings and categories once per matcher" do
    instance = matcher

    assert_queries_count(2) do
      200.times do |index|
        instance.category_for(mcc: [ 5411, 5814, 4121, 4829, 6011 ][index % 5], amount: index.even? ? 100 : -100,
                              description: "Row #{index}")
      end
    end
  end

  test "category_for_group resolves keys and ignores unknown or unmappable groups" do
    assert_equal @groceries, matcher.category_for_group(:groceries)
    assert_equal @groceries, matcher.category_for_group("groceries")
    assert_nil matcher.category_for_group(:own_transfer)
    assert_nil matcher.category_for_group(:nope)
  end
end
