require "test_helper"

class MccCategoryMappingTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @category = categories(:food_and_drink)
  end

  def mapping(key)
    MccCategoryMapping.find_by(family: @family, group_key: key)
  end

  test "apply! stores a category, a disabled group, and removes a row for automatic" do
    MccCategoryMapping.create!(family: @family, group_key: "taxi", disabled: true)

    changed = MccCategoryMapping.apply!(family: @family, choices: {
      "groceries" => @category.id, "cash_withdrawal" => "none", "taxi" => ""
    })

    assert_equal 3, changed
    assert_equal @category, mapping("groceries").category
    assert_not mapping("groceries").disabled?
    assert mapping("cash_withdrawal").disabled?
    assert_nil mapping("cash_withdrawal").category_id
    assert_nil mapping("taxi")
  end

  test "apply! switches an existing row between a category and disabled" do
    MccCategoryMapping.apply!(family: @family, choices: { groceries: "none" })
    MccCategoryMapping.apply!(family: @family, choices: { groceries: @category.id })

    assert_equal @category.id, mapping("groceries").category_id
    assert_not mapping("groceries").disabled?

    MccCategoryMapping.apply!(family: @family, choices: { groceries: "none" })

    assert mapping("groceries").disabled?
    assert_nil mapping("groceries").category_id
    assert_equal 1, MccCategoryMapping.where(family: @family).count
  end

  test "apply! counts nothing when nothing changes" do
    MccCategoryMapping.apply!(family: @family, choices: { groceries: @category.id, taxi: "none" })

    assert_equal 0, MccCategoryMapping.apply!(family: @family, choices: { groceries: @category.id, taxi: "none", rent: "" })
  end

  test "apply! ignores unknown groups, own transfers, foreign categories and junk" do
    foreign = categories(:one)

    changed = MccCategoryMapping.apply!(family: @family, choices: {
      "nope" => "none", "own_transfer" => "none", "health" => "none", "groceries" => foreign.id, "taxi" => "garbage"
    })

    assert_equal 0, changed
    assert_empty MccCategoryMapping.where(family: @family)
  end

  test "apply! keeps groups missing from the choices" do
    MccCategoryMapping.create!(family: @family, group_key: "taxi", disabled: true)

    MccCategoryMapping.apply!(family: @family, choices: { groceries: "none" })

    assert mapping("taxi").disabled?
  end

  test "apply! touches only the given family" do
    MccCategoryMapping.apply!(family: @family, choices: { groceries: "none" })

    assert mcc_category_mappings(:empty_cash_withdrawal).reload.disabled?
    assert_nil MccCategoryMapping.find_by(family: families(:empty), group_key: "groceries")
  end

  test "group keys must be mappable groups" do
    assert_not MccCategoryMapping.new(family: @family, group_key: "own_transfer").valid?
    assert_not MccCategoryMapping.new(family: @family, group_key: "nope").valid?
    assert MccCategoryMapping.new(family: @family, group_key: "groceries").valid?
  end

  test "the category must belong to the family" do
    record = MccCategoryMapping.new(family: @family, group_key: "groceries", category: categories(:one))

    assert_not record.valid?
    assert record.errors.of_kind?(:category, :invalid)
  end

  test "one row per family and group" do
    MccCategoryMapping.create!(family: @family, group_key: "groceries", disabled: true)

    assert_not MccCategoryMapping.new(family: @family, group_key: "groceries").valid?
  end

  test "choice reads none, the category id, or automatic after the category is deleted" do
    disabled = MccCategoryMapping.create!(family: @family, group_key: "taxi", disabled: true)
    chosen = MccCategoryMapping.create!(family: @family, group_key: "groceries", category: @category)

    assert_equal "none", disabled.choice
    assert_equal @category.id, chosen.choice
    assert_equal Mcc::Taxonomy.find(:groceries), chosen.group

    @category.destroy!

    assert_equal "", chosen.reload.choice
  end
end
