# Rows and options for the merchant-code settings section (settings/mcc_mappings/_section).
module MccMappingsHelper
  MccMappingRow = Data.define(:group, :selected, :options)

  # One row per group the family can map, with the select's options and value.
  # Two queries in all (mappings, categories), however many groups.
  def mcc_mapping_rows(family)
    matcher = Mcc::CategoryMatcher.new(family)
    category_options = mcc_category_options(matcher.categories)

    Mcc::Taxonomy.mappable_groups.map do |group|
      mapping = matcher.mapping_for(group)

      MccMappingRow.new(
        group: group,
        selected: mapping&.choice || MccCategoryMapping::AUTOMATIC,
        options: [
          [ mcc_automatic_option_label(group, matcher.automatic_category_for(group)), MccCategoryMapping::AUTOMATIC ],
          [ t("settings.mcc_mappings.section.none"), MccCategoryMapping::NONE ]
        ] + category_options
      )
    end
  end

  private
    def mcc_automatic_option_label(group, category)
      if group.skip?
        t("settings.mcc_mappings.section.automatic_skip")
      elsif category
        t("settings.mcc_mappings.section.automatic", category: category.name)
      else
        t("settings.mcc_mappings.section.automatic_no_match")
      end
    end

    # "Parent › Child" labels, sorted the way the categories page lists them.
    def mcc_category_options(categories)
      by_id = categories.index_by(&:id)

      categories
        .map { |category| [ [ by_id[category.parent_id]&.name, category.name ].compact.join(" › "), category.id ] }
        .sort_by { |label, _| label.downcase }
    end
end
