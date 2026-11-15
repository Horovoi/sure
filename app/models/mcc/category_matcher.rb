# Picks the family category for a card transaction from its merchant code. Used by
# bank connections that report an MCC (monobank today); built once per processing
# pass, so the family's mappings and categories are read with one query each.
#
#   matcher = Mcc::CategoryMatcher.new(family)
#   matcher.category_for(mcc: 5411, amount: 120.5, description: "Сільпо")  # => Category "Groceries"
#
# The group comes from Mcc::Taxonomy. The category for a group is the family's stored
# choice (MccCategoryMapping: a category, or "don't categorise"), else the automatic
# match by name (Mcc::DefaultMapping). Own transfers never get a category; cash
# withdrawals and gambling only get one the family chose.
class Mcc::CategoryMatcher
  attr_reader :family

  def initialize(family)
    @family = family
  end

  # @param mcc [Integer, String, nil]
  # @param original_mcc [Integer, String, nil]
  # @param amount [Numeric] Sure-signed: positive = outflow
  # @param description [String, nil]
  # @param own_transfer [Boolean] the bank connection already knows the money moved
  #   between the owner's own accounts (counterparty IBAN)
  # @return [Mcc::Taxonomy::Group, nil]
  def group_for(mcc:, original_mcc: nil, amount:, description: nil, own_transfer: false)
    return Mcc::Taxonomy.find(Mcc::Taxonomy::OWN_TRANSFER) if own_transfer

    Mcc::Taxonomy.group_for(mcc: mcc, original_mcc: original_mcc, amount: amount, description: description)
  end

  # @return [Category, nil]
  def category_for(mcc:, original_mcc: nil, amount:, description: nil, own_transfer: false)
    group = group_for(mcc: mcc, original_mcc: original_mcc, amount: amount, description: description, own_transfer: own_transfer)
    group && category_for_group(group)
  end

  # The category a group resolves to for this family: stored choice, else automatic.
  # @return [Category, nil]
  def category_for_group(group)
    group = Mcc::Taxonomy.find(group)
    return nil if group.nil? || !group.mappable?

    mapping = mapping_for(group)
    if mapping
      return nil if mapping.disabled?

      stored = mapping.category_id && categories_by_id[mapping.category_id]
      return stored if stored
    end

    automatic_category_for(group)
  end

  # What Mcc::DefaultMapping picks, ignoring the stored choice.
  def automatic_category_for(group)
    default_mapping.category_for(group)
  end

  # @return [MccCategoryMapping, nil]
  def mapping_for(group)
    mappings[Mcc::Taxonomy.find(group)&.key.to_s]
  end

  def categories
    @categories ||= family.categories.to_a
  end

  private
    def mappings
      @mappings ||= MccCategoryMapping.where(family: family).index_by(&:group_key)
    end

    def categories_by_id
      @categories_by_id ||= categories.index_by(&:id)
    end

    def default_mapping
      @default_mapping ||= Mcc::DefaultMapping.new(categories)
    end
end
