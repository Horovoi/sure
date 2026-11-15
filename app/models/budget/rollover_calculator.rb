# Stores BudgetCategory#rolled_over_amount for the family's budgets: what each
# envelope with rollover on carries in from the period before. Fork-native take on
# upstream 1fddb4d97 with the c372b3b98 skip: one family, no personal budgets, so
# there is one chain per family.
#
#   rolled_over(n) = rollover_enabled(n) && rollover_enabled(n-1)
#                    ? max(0, budgeted(n-1) + rolled_over(n-1) - actual(n-1))
#                    : 0
#
# Leftovers only (decision 34): an overspent period carries 0, never a debt.
#
# The amount of period n depends on n-1, which depends on n-2, so it is stored and
# recomputed in one forward pass instead of walked on every render. Only the budget
# page and the budget wizard run it (Budget#recompute_rollover!); find_or_bootstrap,
# the reports and the dashboard never do, so they stay free of writes.
class Budget::RolloverCalculator
  # Namespace of the advisory lock, so it cannot collide with another
  # pg_advisory_lock user
  LOCK_NAMESPACE = 1_920_231_276

  def initialize(family:)
    @family = family
  end

  # Returns true when it changed a stored amount.
  #
  # Two overlapping recomputes could both read the chain and the older one could
  # land its stale carry last, so the read and the write hold a transaction-scoped
  # advisory lock on the family's chain. The cheap checks run first and unlocked:
  # a family that never turned rollover on pays one query, and an unchanged chain
  # (same inputs fingerprint as the last pass that changed nothing) is skipped.
  def recompute!
    return false if first_relevant_budget_date.nil?
    return false if Rails.cache.read(inputs_cache_key) == inputs_fingerprint

    BudgetCategory.transaction do
      lock_chain!
      fingerprint = inputs_fingerprint
      from = first_relevant_budget_date
      wrote = from ? recompute_chain!(from) : false

      # Only a pass that changed nothing proves the stored amounts match these inputs
      Rails.cache.write(inputs_cache_key, fingerprint, expires_in: Family::AGGREGATE_CACHE_TTL) unless wrote
      wrote
    end
  end

  private
    attr_reader :family

    def lock_chain!
      BudgetCategory.connection.execute(
        BudgetCategory.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, hashtext(?))", LOCK_NAMESPACE, chain_key ])
      )
    end

    def chain_key
      "budget_rollover:#{family.id}"
    end

    def inputs_cache_key
      "#{chain_key}:inputs"
    end

    def recompute_chain!(from)
      updates = []
      now = Time.current

      # category_id => [amount, currency]. A budget keeps the currency it was created
      # with, so after a family currency change the amounts on either side are not the
      # same unit: the carry stops there. A deleted category takes its rows with it and
      # drops out of the carry.
      carry = {}

      chain(from).each do |budget|
        next_carry = {}
        ring_fenced_children = ring_fenced_children_by_parent(budget)

        budget.budget_categories.each do |budget_category|
          # A subcategory sharing its parent's amount has no envelope of its own. Clear
          # an amount it kept from when it had one.
          if budget_category.inherits_parent_budget?
            updates << carry_row(budget_category, 0, now) unless budget_category[:rolled_over_amount].to_d.zero?
            next
          end

          incoming = incoming_carry(carry, budget_category)
          updates << carry_row(budget_category, incoming, now) if budget_category[:rolled_over_amount].to_d != incoming

          # Off stops the money in both directions: a period with rollover off sends
          # nothing, so a surplus given up there does not come back a period later.
          outgoing = if budget_category.rollover_enabled?
            leftover_for(budget, budget_category, incoming, ring_fenced_children[budget_category.category_id] || [])
          else
            0
          end

          next_carry[budget_category.category_id] = [ outgoing, budget_category.currency ]
        end

        carry = next_carry
      end

      # The whole row makes the INSERT branch valid (its NOT NULL columns), but only the
      # carry is written on conflict: an allocation changed by a request between our read
      # and this write is not overwritten with the value we read.
      BudgetCategory.upsert_all(updates, unique_by: :id, update_only: %w[rolled_over_amount updated_at]) if updates.any?

      updates.any?
    end

    def carry_row(budget_category, amount, now)
      budget_category.attributes.merge("rolled_over_amount" => amount, "updated_at" => now)
    end

    # Only what the chain reads. Rows are digested, not versioned by max(updated_at), so a
    # write that commits behind a later timestamp or skips updated_at still counts. Entries,
    # accounts and categories go through the same key the income statement caches on, and
    # the family row covers the currency and the fiscal start day.
    def inputs_fingerprint
      budgets = family.budgets
      # Read again: Family#entries_cache_version is memoized on the instance, and the
      # passed family may be older than a write made earlier in the same request
      current_family = Family.select(:id, :currency, :updated_at).find(family.id)

      [
        digest_of(budgets.select(:id, :start_date, :end_date, :budgeted_spending, :currency)),
        digest_of(BudgetCategory.where(budget_id: budgets.select(:id))
          .select(:id, :budget_id, :category_id, :budgeted_spending, :currency, :rollover_enabled, :rolled_over_amount)),
        digest_of(family.accounts.select(*fingerprint_account_columns)),
        current_family.entries_cache_version,
        ExchangeRate.conversion_cache_key(current_family.currency),
        current_family.updated_at.to_f
      ].join("|")
    end

    # The account columns that decide whether an account counts in the spending
    def fingerprint_account_columns
      %w[id status currency exclude_from_reports].select { |column| Account.column_names.include?(column) }
    end

    def digest_of(scope)
      scope.klass.unscoped.from(scope, :rows).pick(Arel.sql("md5(string_agg(rows::text, '|' ORDER BY rows.id))"))
    end

    # Earliest period this chain has anything to say about: rollover on, or a carry left
    # from a toggle switched off that still needs clearing. nil, the common case, costs
    # one query.
    def first_relevant_budget_date
      initialized_budgets
        .joins("INNER JOIN budget_categories ON budget_categories.budget_id = budgets.id")
        .where("budget_categories.rollover_enabled OR budget_categories.rolled_over_amount <> 0")
        .minimum(:start_date)
    end

    # Periods before the first one that uses rollover cannot change a stored amount, so the
    # walk starts one initialized period before it, where its carry comes from.
    def chain(from)
      seed = initialized_budgets.where("start_date < ?", from).maximum(:start_date)

      initialized_budgets
        .where("start_date >= ?", seed || from)
        .order(:start_date)
        .includes(budget_categories: :category)
    end

    # A period never set up is a gap the carry crosses, not a period budgeted at zero
    # (the same rule as Budget#most_recent_initialized_budget).
    def initialized_budgets
      family.budgets.where.not(budgeted_spending: nil)
    end

    def incoming_carry(carry, budget_category)
      return 0.to_d unless budget_category.rollover_enabled?

      amount, currency = carry[budget_category.category_id]
      return 0.to_d if amount.nil? || currency != budget_category.currency

      amount.to_d
    end

    def ring_fenced_children_by_parent(budget)
      budget.budget_categories
        .select { |bc| bc.subcategory? && !bc.inherits_parent_budget? }
        .group_by { |bc| bc.category.parent_id }
    end

    # max(0, budgeted + rolled over - actual). A parent's amount already holds its
    # ring-fenced subcategories' amounts and its spending holds theirs; they carry their
    # own surplus, so they are taken out here and the same money does not roll twice.
    def leftover_for(budget, budget_category, incoming, ring_fenced_children)
      budgeted = (budget_category[:budgeted_spending] || 0) + incoming
      actual = budget.budget_category_actual_spending(budget_category)

      ring_fenced_children.each do |child|
        budgeted -= (child[:budgeted_spending] || 0)
        actual -= budget.budget_category_actual_spending(child)
      end

      [ budgeted - actual, 0 ].max.to_d
    end
end
