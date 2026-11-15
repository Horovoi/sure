# A past transaction name offered by the new-transaction form's name field,
# with the category the family used most often for that exact name.
#
#   Transaction::NameSuggestion.for(family, "coff", classification: "expense")
#
# A query of MIN_QUERY_LENGTH characters or more matches anywhere in the name,
# most used names first. A shorter one matches the start of the name, and a
# blank one lists the most recently used names, so the field offers something
# as soon as it opens. Transfer legs are left out: their names describe a
# transfer, not a purchase.
class Transaction::NameSuggestion
  include ActiveModel::Model

  MIN_QUERY_LENGTH = 3
  DEFAULT_LIMIT = 8

  attr_accessor :name, :category

  class << self
    # classification ("income" or "expense"): only categories of the form's
    # nature are suggested, since the form's category list holds only those.
    def for(family, query, classification: nil, limit: DEFAULT_LIMIT)
      names = matching_names(family, query.to_s.strip, limit)
      return [] if names.empty?

      categories = usual_categories(family, names, classification)
      names.map { |name| new(name: name, category: categories[name]) }
    end

    private
      def base_scope(family)
        Transaction
          .joins(entry: :account)
          .where(accounts: { family_id: family.id, status: Account::VISIBLE_STATUSES })
          .where.not(kind: Transaction::TRANSFER_KINDS)
          .where.not(entries: { name: [ nil, "" ] })
      end

      def matching_names(family, query, limit)
        scope = base_scope(family).group("entries.name").limit(limit)
        return scope.order(Arel.sql("MAX(entries.date) DESC, entries.name")).pluck(Arel.sql("entries.name")) if query.blank?

        escaped = Transaction.sanitize_sql_like(query)
        # A leading wildcard can't use the lower(name) index; the same trade-off as the
        # transaction search, fine for one family's rows.
        pattern = query.length >= MIN_QUERY_LENGTH ? "%#{escaped}%" : "#{escaped}%"

        scope
          .where("entries.name ILIKE ?", pattern)
          .order(Arel.sql("COUNT(*) DESC, MAX(entries.date) DESC, entries.name"))
          .pluck(Arel.sql("entries.name"))
      end

      # The most used category per name, in one grouped query: rows come ordered so
      # the first row of each name is its winner. A tie goes to the latest use.
      def usual_categories(family, names, classification)
        scope = base_scope(family)
          .joins(:category)
          .where(entries: { name: names })
        scope = scope.where(categories: { classification: classification }) if classification.present?

        winners = {}
        scope
          .group("entries.name", "transactions.category_id")
          .order(Arel.sql("entries.name, COUNT(*) DESC, MAX(entries.date) DESC"))
          .pluck(Arel.sql("entries.name"), Arel.sql("transactions.category_id"))
          .each { |name, category_id| winners[name] ||= category_id }

        categories = family.categories.where(id: winners.values.uniq).index_by(&:id)
        winners.transform_values { |id| categories[id] }.compact
      end
  end

  def id
    name
  end

  def to_combobox_display
    name
  end
end
