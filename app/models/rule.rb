class Rule < ApplicationRecord
  # Namespace for the per-family advisory lock around position assignment
  POSITION_LOCK_NAMESPACE = 4013

  UnsupportedResourceTypeError = Class.new(StandardError)
  SUPPORTED_RESOURCE_TYPES = %w[transaction].freeze

  belongs_to :family
  has_many :conditions, dependent: :destroy
  has_many :actions, dependent: :destroy
  has_many :rule_runs, dependent: :destroy

  accepts_nested_attributes_for :conditions, allow_destroy: true
  accepts_nested_attributes_for :actions, allow_destroy: true

  before_validation :normalize_name
  before_create :assign_next_position

  # Rules run top to bottom (Rule::Runner). created_at and id break ties, e.g. for
  # rules created at the same moment before anyone reordered them.
  scope :ordered, -> { order(:position, :created_at, :id) }

  # A null byte or malformed UTF-8 is reported by DatabaseTextValidator instead.
  validates :resource_type, presence: true, inclusion: { in: SUPPORTED_RESOURCE_TYPES, allow_blank: true },
    if: -> { DatabaseTextValidator.acceptable?(resource_type) }
  validates :name, length: { minimum: 1 }, allow_nil: true, if: -> { DatabaseTextValidator.acceptable?(name) }
  validates_with DatabaseTextValidator, attributes: %i[name resource_type]
  validate :no_nested_compound_conditions

  # Every rule must have at least 1 action
  validate :min_actions
  validate :no_duplicate_actions

  def action_executors
    registry.action_executors
  end

  def condition_filters
    registry.condition_filters
  end

  def registry
    @registry ||= case resource_type
    when "transaction"
      Rule::Registry::TransactionResource.new(self)
    else
      raise UnsupportedResourceTypeError, "Unsupported resource type: #{resource_type}"
    end
  end

  # Display-only: a pattern that times out reads as zero here. The failure shows
  # where the rule runs (Rule::Runner records a failed RuleRun).
  def affected_resource_count
    matching_scope.count
  rescue Rule::SafeRegex::TimeoutError
    0
  end

  # Sets the run order of all rules of a family. ordered_ids must list every rule
  # of the family exactly once, so a stale page (a rule added or deleted meanwhile)
  # cannot leave rules with clashing or missing positions.
  def self.update_positions!(family, ordered_ids)
    ordered_ids = Array(ordered_ids).map(&:to_s)
    family_rule_ids = family.rules.pluck(:id)

    unless ordered_ids.size == family_rule_ids.size && ordered_ids.sort == family_rule_ids.sort
      raise ArgumentError, "ordered_ids must list every rule of the family exactly once"
    end

    return if ordered_ids.empty?

    encoder = PG::TextEncoder::Array.new
    sql = sanitize_sql_array([ <<~SQL.squish, encoder.encode(ordered_ids), encoder.encode((1..ordered_ids.size).to_a), family.id ])
      UPDATE rules SET position = new_positions.position
      FROM unnest(?::uuid[], ?::integer[]) AS new_positions(id, position)
      WHERE rules.id = new_positions.id AND rules.family_id = ?
    SQL
    with_connection { |connection| connection.update(sql, "Rule Update Positions") }
  end

  # Excludes transaction ids with one array parameter. where.not(id: ids) sends one
  # bind per id, which breaks beyond PostgreSQL's 65,535 bind limit when a broad
  # rule claims or stops many transactions.
  def self.excluding_transaction_ids(scope, ids)
    return scope if ids.empty?

    scope.where.not("transactions.id = ANY(?::uuid[])", PG::TextEncoder::Array.new.encode(ids.to_a))
  end

  # Active rules that run before this one. "Apply rule" runs them first, so the
  # result matches this rule's turn in the full run.
  def active_rules_above
    ordered_ids = family.rules.ordered.pluck(:id)
    above_ids = ordered_ids.take_while { |id| id != self.id }
    family.rules.where(id: above_ids, active: true).ordered
  end

  # The given transactions without re-checking the conditions, so they stay the
  # same set while the actions change the fields the conditions read.
  def scope_for_transaction_ids(ids)
    registry.resource_scope.where("transactions.id = ANY(?::uuid[])", PG::TextEncoder::Array.new.encode(ids.to_a))
  end

  # Calculates total unique resources affected across multiple rules
  # This handles overlapping rules by deduplicating transaction IDs
  def self.total_affected_resource_count(rules)
    return 0 if rules.empty?

    # Collect all unique transaction IDs matched by any rule
    transaction_ids = Set.new
    rules.each do |rule|
      transaction_ids.merge(rule.matching_scope.pluck(:id))
    rescue Rule::SafeRegex::TimeoutError
      next
    end

    transaction_ids.size
  end

  # Returns an Integer (transactions modified) when every action is synchronous.
  # When any action queues async jobs, returns a Hash:
  #   modified_count:      sync modifications plus transactions queued for async jobs
  #   sync_modified_count: modifications already made synchronously
  #   jobs_count:          async jobs queued
  #
  # scope: the transactions to act on. Rule::Runner passes the matches minus the
  # transactions a rule higher up stopped. claimed_ids maps an attribute to the
  # transaction ids a rule higher up already set it for; an action leaves those
  # transactions alone ("top rule wins").
  def apply(ignore_attribute_locks: false, rule_run: nil, scope: matching_scope, claimed_ids: {})
    sync_modified = 0
    async_queued = 0
    total_async_jobs = 0
    has_async = false

    actions.each do |action|
      excluded_ids = action.claimed_attributes.flat_map { |attribute| claimed_ids.fetch(attribute, []).to_a }.uniq
      action_scope = Rule.excluding_transaction_ids(scope, excluded_ids)
      result = action.apply(action_scope, ignore_attribute_locks: ignore_attribute_locks, rule_run: rule_run)

      if result.is_a?(Hash) && result[:async]
        has_async = true
        total_async_jobs += result[:jobs_count] || 0
        async_queued += result[:modified_count] || 0
      elsif result.is_a?(Integer)
        sync_modified += result
      else
        # Log unexpected result type but don't fail
        Rails.logger.warn("Rule#apply: Unexpected result type from action #{action.id}: #{result.class} (value: #{result.inspect})")
      end
    end

    if has_async
      { modified_count: sync_modified + async_queued, sync_modified_count: sync_modified, async: true, jobs_count: total_async_jobs }
    else
      sync_modified
    end
  end

  # execution_type is "manual" for user-triggered runs and "scheduled" for runs
  # triggered by a sync. The active rules above this one run first (Rule::Runner).
  def apply_later(ignore_attribute_locks: false, execution_type: "manual")
    ApplyRulesJob.perform_later(family, rule_ids: [ id ], ignore_attribute_locks: ignore_attribute_locks, execution_type: execution_type)
  end

  def primary_condition_title
    condition = displayed_condition
    return I18n.t("rules.no_condition") if condition.blank?

    "If #{condition.filter.label.downcase} #{condition.operator_display.downcase} #{condition.value_display}"
  end

  # The condition a summary shows first: an empty compound condition is skipped
  def displayed_condition
    displayable_conditions.first
  end

  def additional_displayable_conditions_count
    [ displayable_conditions.size - 1, 0 ].max
  end

  # One per top-level condition, a compound one standing in for its first sub-condition
  def displayable_conditions
    conditions.filter_map do |condition|
      condition.compound? ? condition.sub_conditions.first : condition
    end
  end

  # Whether this rule's conditions (with its visibility and effective date) match the
  # transaction now. A pattern that times out matches nothing, as when the rule runs.
  def matches_transaction?(transaction)
    matching_scope(only_id: transaction.id).exists?
  rescue Rule::SafeRegex::TimeoutError
    false
  end

  # The transactions this rule's conditions match now. only_id narrows the match to
  # one transaction inside the query, so a pattern runs on that row alone.
  def matching_scope(only_id: nil)
    scope = registry.resource_scope
    scope = scope.where(id: only_id) if only_id

    # 1. Prepare the query with joins required by conditions
    conditions.each do |condition|
      scope = condition.prepare(scope)
    end

    # 2. Apply the conditions to the query
    conditions.each do |condition|
      scope = condition.apply(scope)
    end

    # A pattern is the one condition whose cost the database does not bound by
    # itself, so its matches are resolved here under a statement timeout
    # (Rule::SafeRegex::TimeoutError) and the scope becomes those ids.
    return scope unless conditions.any?(&:uses_regex?)

    scope_for_transaction_ids(Rule::SafeRegex.with_timeout { scope.pluck(:id) })
  end

  # The action the rule list shows: the saved one with the lowest id, picked from
  # preloaded actions without a query.
  def displayed_action
    actions.select(&:persisted?).min_by(&:id)
  end

  # Option lists (categories, merchants, accounts) that conditions and actions look
  # their values up in, loaded once per key. They depend only on the family, so rules
  # listed together share one cache (.share_option_lists).
  attr_writer :option_lists

  def option_list(key)
    @option_lists ||= {}
    @option_lists.fetch(key) { @option_lists[key] = yield }
  end

  def self.share_option_lists(rules)
    option_lists = {}
    rules.each { |rule| rule.option_lists = option_lists }
  end

  def reload(*)
    @option_lists = nil
    @registry = nil
    super
  end

  private
    # Serialized per family with a transaction-scoped advisory lock: without it, two
    # rules created at the same time both read the same MAX(position) and share a
    # position, so their run order would silently fall back to the created_at/id
    # tie-break. before_create runs inside the save transaction, so the lock is held
    # until the new row is committed.
    def assign_next_position
      return if position.to_i.positive?

      self.class.connection.execute(
        self.class.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, hashtext(?))", POSITION_LOCK_NAMESPACE, family_id.to_s ])
      )
      self.position = family.rules.maximum(:position).to_i + 1
    end

    def min_actions
      return if new_record? && !actions.empty?

      if actions.reject(&:marked_for_destruction?).empty?
        errors.add(:base, "must have at least one action")
      end
    end

    def no_duplicate_actions
      action_types = actions.reject(&:marked_for_destruction?).map(&:action_type)

      errors.add(:base, "Rule cannot have duplicate actions #{action_types.inspect}") if action_types.uniq.count != action_types.count
    end

    # Validation: To keep rules simple and easy to understand, we don't allow nested compound conditions.
    def no_nested_compound_conditions
      return true if conditions.none? { |condition| condition.compound? }

      conditions.each do |condition|
        if condition.compound?
          if condition.sub_conditions.any? { |sub_condition| sub_condition.compound? }
            errors.add(:base, "Compound conditions cannot be nested")
          end
        end
      end
    end

    def normalize_name
      return unless name.is_a?(String) && DatabaseTextValidator.acceptable?(name)

      self.name = nil if name.strip.empty?
    end
end
