require "test_helper"

class CategoryTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
  end

  test "replacing and destroying" do
    transactions = categories(:food_and_drink).transactions.to_a

    categories(:food_and_drink).replace_and_destroy!(categories(:income))

    assert_equal categories(:income), transactions.map { |t| t.reload.category }.uniq.first
  end

  test "replacing with nil should nullify the category" do
    transactions = categories(:food_and_drink).transactions.to_a

    categories(:food_and_drink).replace_and_destroy!(nil)

    assert_nil transactions.map { |t| t.reload.category }.uniq.first
  end

  test "subcategory can only be one level deep" do
    category = categories(:subcategory)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      category.subcategories.create!(name: "Invalid category", family: @family)
    end

    assert_equal "Validation failed: Parent can't have more than 2 levels of subcategories", error.message
  end

  test "grouped select options include parent and subcategories" do
    options = Category.grouped_select_options(
      @family.categories.includes(:subcategories).roots.alphabetically
    )

    food_group = options.find { |label, _| label == "Food & Drink" }
    assert food_group, "expected Food & Drink group to be present"

    option_labels = food_group.last.map(&:first)
    option_ids = food_group.last.map(&:second)

    assert_equal [ "Food & Drink", "Restaurants" ], option_labels
    assert_equal [ categories(:food_and_drink).id, categories(:subcategory).id ], option_ids
  end

  test "accepts six-digit hex colors" do
    [ "#FFFFFF", "#000000", "#123456", "#ABCDEF", "#abcdef" ].each do |color|
      category = Category.new(name: "Category #{color}", color: color, lucide_icon: "shapes", family: @family)
      assert category.valid?, "#{color} should be valid"
    end
  end

  test "rejects a color that is not six-digit hex" do
    [ "invalid", "#123", "#1234567", "#GGGGGG", "red", "ffffff", "#ffff" ].each do |color|
      category = Category.new(name: "Category #{color}", color: color, lucide_icon: "shapes", family: @family)
      assert_not category.valid?, "#{color} should be invalid"
      assert category.errors.of_kind?(:color, :invalid)
    end
  end

  test "an existing category with an old non-hex color still saves other fields" do
    category = categories(:income)
    category.update_column(:color, "#abc")

    assert category.update(name: "Renamed income")
    assert_not category.update(color: "#abcd"), "changing to a bad color is still rejected"
  end

  test "changing a parent's color updates its subcategories" do
    parent = categories(:food_and_drink)
    subcategory = categories(:subcategory)
    previous_updated_at = subcategory.updated_at

    travel 1.second do
      parent.update!(color: "#123456")
    end

    subcategory.reload
    assert_equal "#123456", subcategory.color
    assert_operator subcategory.updated_at, :>, previous_updated_at
  end

  test "totals_key is the id of a persisted category and a symbol for the synthetic ones" do
    assert_equal categories(:food_and_drink).id, categories(:food_and_drink).totals_key
    assert_equal :uncategorized, @family.categories.uncategorized.totals_key
    assert_equal :other_investments, @family.categories.other_investments.totals_key
  end

  # --- DS pickers (w1-ds) ---

  test "a new subcategory takes its parent's classification" do
    parent = @family.categories.create!(name: "Salary", color: "#22c55e", classification: "income", lucide_icon: "briefcase")

    child = @family.categories.create!(name: "Overtime", color: "#22c55e", classification: "expense", lucide_icon: "clock", parent: parent)

    assert_equal "income", child.classification
  end

  test "an existing subcategory cannot move to a classification its parent doesn't have" do
    child = categories(:subcategory)

    assert_not child.update(classification: "income")
    assert child.errors[:parent].any?
  end

  test "classification is normalized and must be income or expense" do
    category = @family.categories.create!(name: "Gifts in", color: "#22c55e", classification: " Income ", lucide_icon: "gift")
    assert_equal "income", category.classification

    invalid = @family.categories.new(name: "Odd", color: "#22c55e", classification: "transfer", lucide_icon: "gift")
    assert_not invalid.valid?
    assert invalid.errors[:classification].any?
  end

  test "a parent must belong to the same family" do
    foreign_parent = categories(:one)

    category = @family.categories.new(name: "Cross", color: "#22c55e", classification: "expense", lucide_icon: "layers", parent: foreign_parent)

    assert_not category.valid?
    assert category.errors[:parent].any?
  end

  test "recently_used_for lists picked categories, newest first, without the excluded ones" do
    older = categories(:food_and_drink)
    newer = categories(:subscriptions)
    excluded = categories(:subcategory)
    older.update!(last_used_at: 2.days.ago)
    newer.update!(last_used_at: 1.hour.ago)
    excluded.update!(last_used_at: 1.minute.ago)

    recent = Category.recently_used_for(family: @family, excluding: excluded).to_a

    assert_equal [ newer, older ], recent
  end

  test "recently_used_for can keep one classification and caps the count" do
    income = @family.categories.create!(name: "Salary", color: "#22c55e", classification: "income", lucide_icon: "briefcase", last_used_at: 1.minute.ago)
    categories(:food_and_drink).update!(last_used_at: 1.hour.ago)

    assert_equal [ income ], Category.recently_used_for(family: @family, classification: "income").to_a
    assert_equal 1, Category.recently_used_for(family: @family, limit: 1).count
  end

  test "recently_used_for ignores categories never picked by hand" do
    assert_empty Category.recently_used_for(family: @family)
  end

  test "every icon_codes name renders through lucide-rails" do
    codes = Category.icon_codes

    assert_equal codes.uniq, codes, "icon_codes has duplicates"
    codes.each do |code|
      svg = ApplicationController.helpers.lucide_icon(code)
      assert_includes svg, "<svg", "#{code} did not render"
    end
  end

  test "icon_codes keeps the modern upstream names and the icons categories already use" do
    codes = Category.icon_codes

    %w[shapes circle-dollar-sign drama pill dumbbell hand-helping receipt piggy-bank store].each do |modern|
      assert_includes codes, modern
    end
    # Icons that existing categories got from the earlier shorter list and rename
    %w[layers dollar-sign film stethoscope target gift file-text trending-up star building scan bar-chart calendar].each do |kept|
      assert_includes codes, kept
    end
  end

  test "bootstrap gives a new family the modern default icons, all of them in icon_codes" do
    family = families(:empty)
    family.categories.bootstrap!

    assert_equal "circle-dollar-sign", family.categories.find_by!(name: "Income").lucide_icon
    assert_equal "drama", family.categories.find_by!(name: "Entertainment").lucide_icon
    assert_equal "piggy-bank", family.categories.find_by!(name: "Savings & Investments").lucide_icon
    family.categories.each do |category|
      assert_includes Category.icon_codes, category.lucide_icon, "#{category.name} has an icon the form does not offer"
    end
  end

  test "the uncategorized placeholder uses the circle-dashed icon" do
    assert_equal "circle-dashed", Category.uncategorized.lucide_icon
  end
end
