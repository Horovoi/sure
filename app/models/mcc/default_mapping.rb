# The automatic category for an Mcc::Taxonomy group: the family category whose name
# matches one of the group's aliases (English, then Ukrainian), then the aliases of
# each fallback group in order (coffee -> "Coffee Out", else "Eating Out", else
# "Food & Drinks"). Names compare case-, punctuation- and apostrophe-insensitively,
# "&", "and", "та", "і" and "й" are ignored, English words are singularised and
# Ukrainian words lose their ending vowel, so "Pharmacies" = "pharmacy", "Food & Drinks"
# = "food and drinks", "Аптеки" = "аптека".
#
# A spending group only matches expense categories and an income group only income
# categories (a refund matches either). Skipped groups (own transfers, cash, gambling)
# get nothing. Never creates a category.
class Mcc::DefaultMapping
  CONJUNCTIONS = %w[and та і й].to_set.freeze
  LATIN_WORD = /\A[a-z0-9]+\z/
  CYRILLIC_ENDING = /[аеєиіїоуюяь]\z/

  class << self
    def normalize(name)
      name.to_s.unicode_normalize(:nfkc).downcase
        .delete("'ʼ’`´")
        .gsub(/[&+]/, " and ")
        .split(/[^[:alnum:]]+/)
        .reject { |word| word.empty? || CONJUNCTIONS.include?(word) }
        .map { |word| stem(word) }
        .join(" ")
    end

    private
      def stem(word)
        if word.match?(LATIN_WORD)
          word.singularize
        elsif word.length > 3
          word.sub(CYRILLIC_ENDING, "")
        else
          word
        end
      end
  end

  # @param categories [Enumerable<Category>] the family's categories
  def initialize(categories)
    @index = categories
      .sort_by { |category| [ category.parent_id.nil? ? 0 : 1, category.name.to_s.downcase, category.id.to_s ] }
      .group_by { |category| self.class.normalize(category.name) }
    @cache = {}
  end

  # @param group [Mcc::Taxonomy::Group, Symbol, String]
  # @return [Category, nil]
  def category_for(group)
    group = Mcc::Taxonomy.find(group)
    return nil if group.nil? || group.skip? || !group.mappable?

    @cache.fetch(group.key) { @cache[group.key] = find_category(group) }
  end

  private
    attr_reader :index

    def find_category(group)
      candidates = [ group, *group.fallbacks.filter_map { |key| Mcc::Taxonomy.find(key) } ]

      candidates.each do |candidate|
        candidate.aliases.each do |alias_name|
          match = index.fetch(self.class.normalize(alias_name), []).find { |category| compatible?(category, group) }
          return match if match
        end
      end

      nil
    end

    def compatible?(category, group)
      group.classification.nil? || category.classification == group.classification
    end
end
