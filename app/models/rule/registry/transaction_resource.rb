class Rule::Registry::TransactionResource < Rule::Registry
  CONDITION_FILTER_CLASSES = [
    Rule::ConditionFilter::TransactionName,
    Rule::ConditionFilter::TransactionAmount,
    Rule::ConditionFilter::TransactionType,
    Rule::ConditionFilter::TransactionMerchant,
    Rule::ConditionFilter::TransactionCategory,
    Rule::ConditionFilter::TransactionTag,
    Rule::ConditionFilter::TransactionDetails,
    Rule::ConditionFilter::TransactionNotes,
    Rule::ConditionFilter::TransactionAccount
  ].freeze

  # Every action this resource knows, whether or not it is offered right now: the AI
  # actions are listed only while an LLM provider is configured (or the rule already
  # has one), but a saved AI action stays readable when the provider goes away.
  ACTION_EXECUTOR_CLASSES = [
    Rule::ActionExecutor::SetTransactionCategory,
    Rule::ActionExecutor::SetTransactionTags,
    Rule::ActionExecutor::SetTransactionMerchant,
    Rule::ActionExecutor::SetTransactionName,
    Rule::ActionExecutor::SetInvestmentActivityLabel,
    Rule::ActionExecutor::ExcludeTransaction,
    Rule::ActionExecutor::SetAsTransferOrPayment,
    Rule::ActionExecutor::BayesCategorize,
    Rule::ActionExecutor::AutoCategorize,
    Rule::ActionExecutor::AutoDetectMerchants
  ].freeze

  AI_ACTION_KEYS = %w[auto_categorize auto_detect_merchants].freeze

  # The types a saved condition or action may have. Validation reads these static
  # lists, not the offered menu, so a saved AI action stays valid without a provider.
  def self.condition_filter_keys
    CONDITION_FILTER_CLASSES.map(&:key)
  end

  def self.action_executor_keys
    ACTION_EXECUTOR_CLASSES.map(&:key)
  end

  # Rules act on what a transaction is for: the parts of a split, never its parent
  # (Entry::Splittable). A part's category, merchant and tags picked in the split
  # editor are locked, so a rule only fills what the user left open.
  def resource_scope
    family.transactions.visible.with_entry.merge(Entry.excluding_split_parents).where(entry: { date: rule.effective_date.. })
  end

  def condition_filters
    CONDITION_FILTER_CLASSES.map { |filter_class| filter_class.new(rule) }
  end

  def action_executors
    ACTION_EXECUTOR_CLASSES.filter_map do |executor_class|
      executor_class.new(rule) if offered?(executor_class)
    end
  end

  # Single lookups build only the class asked for, once per registry: listing every
  # executor checks the AI provider on each call, and a rule list looks up each
  # condition and action several times.
  def get_filter!(key)
    @filters_by_key ||= {}
    @filters_by_key[key] ||= begin
      filter_class = CONDITION_FILTER_CLASSES.find { |klass| klass.key == key }
      raise UnsupportedConditionError, "Unsupported condition type: #{key}" unless filter_class
      filter_class.new(rule)
    end
  end

  def get_executor!(key)
    @executors_by_key ||= {}
    @executors_by_key[key] ||= begin
      executor_class = ACTION_EXECUTOR_CLASSES.find { |klass| klass.key == key }
      raise UnsupportedActionError, "Unsupported action type: #{key}" unless executor_class && offered?(executor_class)
      executor_class.new(rule)
    end
  end

  private
    def offered?(executor_class)
      return true unless AI_ACTION_KEYS.include?(executor_class.key)

      existing_action?(executor_class.key) || ai_enabled?
    end

    def ai_enabled?
      return @ai_enabled if defined?(@ai_enabled)

      @ai_enabled = Provider::Registry.get_provider(:openai).present?
    end

    def existing_action?(action_type)
      rule.actions.any? { |action| action.action_type == action_type }
    end
end
