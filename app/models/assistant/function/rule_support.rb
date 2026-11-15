# Shared by the rule tools (get_rules, get_rule_options, preview_rule, create_rule, update_rule, apply_rule). Hand
# port of upstream ec5cbd901 and 928434e59 onto the fork's ordered Rule::Runner and RuleRun.
#
# A rule rewrites every transaction it matches, and an active rule runs again after every sync. So create_rule and
# update_rule always save a rule inactive, and only apply_rule activates one. apply_rule needs a preview_token, which
# a preview that listed the matches issues (preview_rule, create_rule and update_rule return one; get_rules never
# does). The token is signed and bound to the user, the rule's definition and its match count, so a skipped preview,
# a token from before an edit, or a token for matches that have changed since are all refused. The model makes the
# preview call itself: it is not a confirmation step with the user (owner answer 2).
#
# The fork has one family and no account sharing, so every account, category, tag and merchant of the family can
# be named in a rule, and the preview sample covers every match.
module Assistant::Function::RuleSupport
  # Actions that call an AI model cost money per transaction. Settings > Rules shows a cost estimate before it runs
  # them; the tools cannot, so these stay in the UI.
  BLOCKED_ACTION_TYPES = Rule::Registry::TransactionResource::AI_ACTION_KEYS

  # Condition and action types whose value is an id, by the list the id comes from
  ACCOUNT_KEYS = %w[transaction_account set_as_transfer_or_payment].freeze
  CATEGORY_KEYS = %w[transaction_category set_transaction_category].freeze
  TAG_KEYS = %w[transaction_tag set_transaction_tags].freeze
  MERCHANT_KEYS = %w[transaction_merchant set_transaction_merchant].freeze

  DEFAULT_SAMPLE_SIZE = 10
  MAX_SAMPLE_SIZE = 25

  PREVIEW_TOKEN_TTL = 30.minutes

  SAMPLE_SIZE_DESCRIPTION = "Matches to list, most recent first (default #{DEFAULT_SAMPLE_SIZE}, max #{MAX_SAMPLE_SIZE})."

  # JSON schema fragments shared by preview_rule, create_rule and update_rule
  def condition_schema
    {
      type: "object",
      properties: {
        condition_type: {
          type: "string",
          description: "A condition_type from get_rule_options, or \"compound\" to group sub_conditions."
        },
        operator: {
          type: "string",
          description: "An operator value from get_rule_options for this condition. For compound: \"and\" or \"or\"."
        },
        value: {
          type: "string",
          description: "Text, a number, or an id (account, category, tag, merchant) depending on the condition. Omit for is_null / is_not_null and for compound."
        },
        sub_conditions: {
          type: "array",
          description: "Only for compound conditions: one level of plain conditions (no nesting).",
          items: { type: "object" }
        }
      },
      required: %w[condition_type operator]
    }
  end

  def action_schema
    {
      type: "object",
      properties: {
        action_type: {
          type: "string",
          description: "An action_type from get_rule_options."
        },
        value: {
          description: "A category, merchant or account id, an activity label or a new name depending on the action; an array of tag ids for set_transaction_tags. Omit for actions without a value.",
          anyOf: [ { type: "string" }, { type: "array", items: { type: "string" } } ]
        }
      },
      required: %w[action_type]
    }
  end

  def definition_properties
    {
      conditions: {
        type: "array",
        description: "Every condition must match (AND). Use a compound condition with operator \"or\" for alternatives.",
        items: condition_schema
      },
      actions: {
        type: "array",
        description: "At least one action. Each action type may appear once.",
        items: action_schema
      },
      effective_date: {
        type: "string",
        description: "Optional YYYY-MM-DD. The rule only touches transactions dated on or after this day."
      }
    }
  end

  def sample_size_property
    { type: "integer", minimum: 0, maximum: MAX_SAMPLE_SIZE, description: SAMPLE_SIZE_DESCRIPTION }
  end

  private
    # A rule of the user's family, or nil for an unknown id or another family's rule
    def find_rule(id)
      return nil unless valid_uuid?(id)

      family.rules.includes(:actions, conditions: :sub_conditions).find_by(id: id)
    end

    def rule_not_found
      tool_error("not_found", "Use a rule id from get_rules.")
    end

    def ai_action?(rule)
      rule.actions.any? { |action| BLOCKED_ACTION_TYPES.include?(action.action_type) }
    end

    # Replaces the rule's conditions and actions with the given definition and returns a list of problems. The rule
    # is not saved. A key that is absent leaves that part of the rule unchanged.
    def assign_definition(rule, params)
      problems = []

      if params.key?("effective_date")
        raw = params["effective_date"]
        if raw.blank?
          rule.effective_date = nil
        else
          begin
            rule.effective_date = Date.iso8601(raw.to_s)
          rescue Date::Error
            problems << "effective_date must be a YYYY-MM-DD date."
          end
        end
      end

      if params.key?("conditions")
        conditions = params["conditions"]
        if conditions.is_a?(Array)
          rule.conditions.each(&:mark_for_destruction)
          conditions.each_with_index do |condition, index|
            problems.concat(build_condition(rule, rule.conditions, condition, "conditions[#{index}]", allow_compound: true))
          end
        else
          problems << "conditions must be an array."
        end
      end

      if params.key?("actions")
        actions = params["actions"]
        if actions.is_a?(Array)
          rule.actions.each(&:mark_for_destruction)
          actions.each_with_index do |action, index|
            problems.concat(build_action(rule, action, "actions[#{index}]"))
          end
        else
          problems << "actions must be an array."
        end
      end

      problems
    end

    def build_condition(rule, collection, attrs, path, allow_compound:)
      return [ "#{path} must be an object." ] unless attrs.is_a?(Hash)

      type = attrs["condition_type"].to_s
      operator = attrs["operator"].to_s

      if type == "compound"
        return [ "#{path}: compound conditions cannot be nested." ] unless allow_compound
        return [ "#{path}: compound operator must be \"and\" or \"or\"." ] unless Rule::Condition::COMPOUND_OPERATORS.include?(operator)

        subs = attrs["sub_conditions"]
        return [ "#{path}: compound conditions need at least one sub_condition." ] unless subs.is_a?(Array) && subs.any?

        compound = collection.build(condition_type: "compound", operator: operator)
        return subs.each_with_index.flat_map do |sub, index|
          build_condition(rule, compound.sub_conditions, sub, "#{path}.sub_conditions[#{index}]", allow_compound: false)
        end
      end

      filter = rule.condition_filters.find { |f| f.key == type }
      return [ "#{path}: unknown condition_type '#{type}'. See get_rule_options." ] unless filter

      operators = filter.operators.map(&:last)
      return [ "#{path}: operator '#{operator}' is not valid for #{type}. Valid: #{operators.join(", ")}." ] unless operators.include?(operator)

      value = attrs["value"]
      if Rule::ConditionFilter::VALUELESS_OPERATORS.include?(operator)
        value = nil
      else
        # A pattern is matched as given (see Rule::ConditionFilter::REGEX_OPERATORS), so only plain text is trimmed
        value = Rule::ConditionFilter::REGEX_OPERATORS.include?(operator) ? value.to_s : value.to_s.strip
        return [ "#{path}: value is required for operator '#{operator}'." ] if value.blank?
        return [ "#{path}: value must be a number." ] if filter.type == "number" && !numeric?(value)

        allowed = allowed_values(rule, type)
        return [ "#{path}: '#{value}' is not a valid value for #{type}. #{value_hint(rule, type)}" ] if allowed && !allowed.include?(value)
      end

      collection.build(condition_type: type, operator: operator, value: value)
      []
    end

    def build_action(rule, attrs, path)
      return [ "#{path} must be an object." ] unless attrs.is_a?(Hash)

      type = attrs["action_type"].to_s
      if BLOCKED_ACTION_TYPES.include?(type)
        return [ "#{path}: #{type} calls an AI model and is not available here; it is added in Settings > Rules, which shows the cost first." ]
      end

      executor = rule.action_executors.find { |e| e.key == type }
      return [ "#{path}: unknown action_type '#{type}'. See get_rule_options." ] unless executor

      value = attrs["value"]
      case executor.type
      when "function"
        value = nil
      when "multi_select"
        values = Array(value).map { |v| v.to_s.strip }.compact_blank.uniq
        return [ "#{path}: value must list at least one id for #{type}." ] if values.empty?

        invalid = values - Array(allowed_values(rule, type))
        return [ "#{path}: #{invalid.join(", ")} not valid for #{type}. #{value_hint(rule, type)}" ] if invalid.any?

        value = values
      else
        return [ "#{path}: value must be a single string for #{type}." ] if value.is_a?(Array)

        value = value.to_s.strip
        return [ "#{path}: value is required for #{type}." ] if value.blank?

        allowed = allowed_values(rule, type)
        return [ "#{path}: '#{value}' is not a valid value for #{type}. #{value_hint(rule, type)}" ] if allowed && !allowed.include?(value)
      end

      rule.actions.build(action_type: type, value: value)
      []
    end

    # Runs the model validations (operators the filter does not offer, unsafe patterns, duplicate actions), then builds
    # each condition's query without running it. Returns a list of problems.
    def validate_rule(rule)
      return rule.errors.full_messages unless rule.valid?

      scope = rule.registry.resource_scope
      rule.conditions.reject(&:marked_for_destruction?).each { |c| c.apply(c.prepare(scope)) }
      []
    rescue Rule::ConditionFilter::UnsupportedOperatorError => e
      [ e.message ]
    end

    # The values a condition or action accepts, from the same option lists the rule form offers, or nil for free text
    def allowed_values(rule, key)
      @allowed_values ||= {}
      return @allowed_values[key] if @allowed_values.key?(key)

      @allowed_values[key] = case key
      when "set_transaction_name", "transaction_name", "transaction_notes", "transaction_details", "transaction_amount"
        nil
      else
        options = option_pairs(rule, key)
        options&.map { |_label, value| value.to_s }
      end
    end

    # [[label, value], ...] of a condition filter or action executor, or nil when it has no fixed list
    def option_pairs(rule, key)
      source = rule.condition_filters.find { |f| f.key == key } || rule.action_executors.find { |e| e.key == key }
      source&.options
    end

    def value_hint(rule, key)
      case key
      when *ACCOUNT_KEYS then "Use an account id from get_accounts."
      when *CATEGORY_KEYS then "Use a category id from get_categories."
      when *TAG_KEYS then "Use tag ids from get_tags."
      when *MERCHANT_KEYS then "Use a merchant id from get_merchants."
      else "Valid: #{Array(allowed_values(rule, key)).join(", ")}."
      end
    end

    def numeric?(value)
      BigDecimal(value)
      true
    rescue ArgumentError
      false
    end

    # The rule in readable form: ids come with their names
    def serialize_rule(rule, include_last_run: false)
      data = {
        id: rule.id,
        name: rule.name,
        active: rule.active,
        position: rule.position,
        stop_processing: rule.stop_processing,
        effective_date: rule.effective_date&.iso8601,
        conditions: top_level_conditions(rule).map { |c| serialize_condition(c) },
        actions: live_actions(rule).map { |a| serialize_action(a) },
        updated_at: local_time(rule.updated_at)
      }

      if include_last_run
        run = rule.rule_runs.recent.first
        data[:last_run] = run && serialize_rule_run(run)
      end

      data
    end

    def serialize_rule_run(run)
      {
        id: run.id,
        executed_at: local_time(run.executed_at),
        status: run.status,
        execution_type: run.execution_type,
        transactions_queued: run.transactions_queued,
        transactions_processed: run.transactions_processed,
        transactions_modified: run.transactions_modified,
        error_message: run.error_message
      }.compact
    end

    # Timestamps in the family's time zone (the chat and /mcp agree with the rules page)
    def local_time(time)
      time&.in_time_zone(family.resolved_time_zone)&.iso8601
    end

    def top_level_conditions(rule)
      rule.conditions.reject(&:marked_for_destruction?).select { |c| c.parent_id.nil? }
    end

    def live_actions(rule)
      rule.actions.reject(&:marked_for_destruction?)
    end

    def serialize_condition(condition)
      if condition.compound?
        {
          condition_type: "compound",
          operator: condition.operator,
          sub_conditions: condition.sub_conditions.reject(&:marked_for_destruction?).map { |sub| serialize_condition(sub) }
        }
      else
        {
          condition_type: condition.condition_type,
          operator: condition.operator,
          value: condition.value,
          value_name: value_name(condition.condition_type, condition.value)
        }.compact
      end
    end

    def serialize_action(action)
      names = action_values(action).filter_map { |v| value_name(action.action_type, v) }

      {
        action_type: action.action_type,
        value: action.value,
        value_name: names.any? ? names.join(", ") : nil
      }.compact
    end

    def action_values(action)
      return [] if action.value.blank?

      action.action_type.in?(TAG_KEYS) ? action.value.to_s.split(",") : [ action.value.to_s ]
    end

    # The name behind an id-valued condition or action, or nil for free text
    def value_name(key, value)
      return nil if value.blank?

      names = name_lookup(key)
      return nil unless names

      names.fetch(value.to_s, "(deleted)")
    end

    def name_lookup(key)
      @name_lookups ||= {}
      group =
        case key
        when *ACCOUNT_KEYS then :accounts
        when *CATEGORY_KEYS then :categories
        when *TAG_KEYS then :tags
        when *MERCHANT_KEYS then :merchants
        end
      return nil unless group

      @name_lookups[group] ||=
        case group
        when :accounts then family.accounts.pluck(:id, :name).to_h { |id, name| [ id.to_s, name ] }
        when :categories then family.categories.includes(:parent).to_h { |c| [ c.id.to_s, c.name_with_parent ] }
        when :tags then family.tags.pluck(:id, :name).to_h { |id, name| [ id.to_s, name ] }
        when :merchants then merchant_names
        end
    end

    # A merchant condition may name a provider merchant (Family#available_merchants); an action sets a family one
    def merchant_names
      (family.available_merchants.to_a + family.merchants.to_a).to_h { |m| [ m.id.to_s, m.name ] }
    end

    # What applying the rule would touch: every match in the family (there is no account sharing), the most recent
    # ones as a sample with their current category and merchant, and the actions in readable form.
    #
    # Rules higher up in the list run first when the rule is applied. One of them with stop_processing can leave some
    # of these matches alone, so the count is the most the rule changes.
    def preview(rule, sample_size: DEFAULT_SAMPLE_SIZE)
      scope = rule.matching_scope
      match_count = scope.count

      sample = scope
        .includes(:merchant, category: :parent, entry: :account)
        .order("entries.date DESC, entries.id DESC")
        .limit(sample_size)
        .to_a

      {
        match_count: match_count,
        sample: sample.map { |txn| serialize_sample(txn) },
        actions: live_actions(rule).map { |a| describe_action(a) },
        preview_token: preview_token(rule, match_count, shown: sample.size)
      }.compact
    end

    # A preview that could not run: a pattern that timed out (Rule::SafeRegex) matches nothing when the rule runs
    def preview_or_error(rule, sample_size:)
      [ preview(rule, sample_size: sample_size), nil ]
    rescue Rule::SafeRegex::TimeoutError
      [ nil, tool_error("pattern_timeout", "A matches_regex pattern took too long to run. Use a simpler pattern or a contains condition.") ]
    end

    # Issued for a saved, unchanged rule when the preview listed its matches: none for sample_size 0 when there are
    # matches. A rule that matches nothing gets one, so a rule meant for future transactions can be activated.
    def preview_token(rule, match_count, shown:)
      return nil unless rule.persisted? && !rule.changed?
      return nil if match_count.positive? && shown.zero?

      preview_verifier.generate(
        { "rule_id" => rule.id, "user_id" => user.id, "definition" => definition_digest(rule), "match_count" => match_count },
        purpose: :apply_rule, expires_in: PREVIEW_TOKEN_TTL
      )
    end

    # The token's payload, or nil when it is missing, forged, expired, or issued to another user or rule
    def read_preview_token(token, rule)
      payload = preview_verifier.verified(token.to_s, purpose: :apply_rule) if token.present?
      return nil unless payload.is_a?(Hash)
      return nil unless payload["rule_id"] == rule.id && payload["user_id"] == user.id

      payload
    end

    # What the rule does, independent of timestamps and display names
    def definition_digest(rule)
      definition = {
        effective_date: rule.effective_date&.iso8601,
        conditions: top_level_conditions(rule).map { |c| digest_condition(c) }.sort_by(&:to_json),
        actions: live_actions(rule).map { |a| [ a.action_type, a.value.to_s ] }.sort
      }
      Digest::SHA256.hexdigest(definition.to_json)
    end

    def digest_condition(condition)
      if condition.compound?
        return [ condition.operator, condition.sub_conditions.reject(&:marked_for_destruction?).map { |sub| digest_condition(sub) }.sort_by(&:to_json) ]
      end

      [ condition.condition_type, condition.operator, condition.value.to_s ]
    end

    def preview_verifier
      Rails.application.message_verifier("assistant/rule_preview")
    end

    def serialize_sample(txn)
      entry = txn.entry
      {
        id: txn.id,
        date: entry.date.iso8601,
        account: entry.account.name,
        name: entry.name,
        amount: entry.amount.to_s("F"),
        currency: entry.currency,
        category: txn.category&.name_with_parent,
        merchant: txn.merchant&.name,
        excluded: entry.excluded
      }
    end

    def describe_action(action)
      serialize_action(action).merge(label: action.executor.label)
    rescue Rule::Registry::UnsupportedActionError
      serialize_action(action)
    end

    def resolved_sample_size(params)
      return DEFAULT_SAMPLE_SIZE if params["sample_size"].blank?

      params["sample_size"].to_i.clamp(0, MAX_SAMPLE_SIZE)
    end

    # The fields a rule action can change, per transaction id, for the audit snapshot and to tell which matches
    # apply_rule actually changed
    def rule_fields_by_transaction(ids)
      ids = Array(ids).uniq
      return {} if ids.empty?

      encoded = PG::TextEncoder::Array.new.encode(ids)
      rows = Transaction.joins(:entry)
        .where("transactions.id = ANY(?::uuid[])", encoded)
        .pluck("transactions.id", "entries.name", "transactions.category_id", "transactions.merchant_id",
          "transactions.kind", "entries.excluded", "transactions.investment_activity_label")
      tags = Tagging.where(taggable_type: "Transaction").where("taggable_id = ANY(?::uuid[])", encoded)
        .pluck(:taggable_id, :tag_id).group_by(&:first).transform_values { |pairs| pairs.map(&:last).sort }

      rows.to_h do |id, name, category_id, merchant_id, kind, excluded, label|
        [ id, {
          "id" => id, "name" => name, "category_id" => category_id, "merchant_id" => merchant_id, "kind" => kind,
          "excluded" => excluded, "investment_activity_label" => label, "tag_ids" => tags.fetch(id, [])
        } ]
      end
    end
end
