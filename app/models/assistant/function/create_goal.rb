# Creates a savings goal as the New goal form does (w3-reports goal-ai-hooks). Hand port of upstream's
# create_goal on the fork's goals: the family's active manual accounts of a fundable type (Depository,
# Investment, Crypto) by id from get_accounts, the target in the family currency, one-off goals and reserves,
# and a reserve sized in months of expenses (the median fiscal month, refreshed each fiscal month by
# RefreshMaintainedGoalTargetsJob). One family, so no sharing.
#
# Served to the in-app chat and /mcp alike, with no approval prompt (owner answer 2); every call is audited.
class Assistant::Function::CreateGoal < Assistant::Function
  scope_tag :write

  class << self
    def name
      "create_goal"
    end

    def description
      <<~INSTRUCTIONS
        Creates a savings goal for the family: something to save toward ("a
        trip in 4 months for 50,000"), or a reserve to keep ("an emergency fund
        of 6 months of expenses").

        Before calling, confirm the name, the target, the date (if any) and the
        accounts that fund it with the user.

        - kind: "one_off" (default) is reached once; "maintained" is a reserve
          to hold, with no target date.
        - target_amount is in the family currency. For a reserve, target_months
          instead sizes it as that many median months of the family's spending.
        - account_ids: one or more accounts from get_accounts that fund the
          goal (cash, investment or crypto accounts). An account claimed in
          full by another goal needs an earmark: pass earmarks as
          {account_id: amount}, in that account's currency. An account left out
          of earmarks backs the goal with its whole balance.

        A soft error lists the accounts that can fund a goal, with what each
        has left to earmark.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[name account_ids],
      properties: {
        name: { type: "string", description: "Short goal name, e.g. 'Trip to Lviv'" },
        kind: { type: "string", enum: Goal::KINDS, description: "one_off (default) or maintained (a reserve)" },
        target_amount: { type: "number", description: "Amount to save, in the family currency. Not needed with target_months" },
        target_months: { type: "integer", description: "Reserves only: size the target as this many median months of spending" },
        target_date: { type: "string", description: "Optional YYYY-MM-DD for a one-off goal" },
        account_ids: {
          type: "array",
          items: { type: "string" },
          description: "Ids from get_accounts of the accounts that fund the goal; at least one"
        },
        earmarks: {
          type: "object",
          additionalProperties: { type: "number" },
          description: "Optional {account_id: amount} to reserve from an account, in that account's currency"
        },
        notes: { type: "string", description: "Optional notes" }
      }
    )
  end

  def record_type
    "Goal"
  end

  def call(params = {})
    name = params["name"].to_s.squish
    return tool_error("invalid_name", "name is required.") if name.empty?

    kind = params["kind"].presence || "one_off"
    return tool_error("invalid_kind", "kind must be one_off or maintained.") unless Goal::KINDS.include?(kind)

    target_amount = parse_decimal(params["target_amount"])
    target_months = parse_integer(params["target_months"])
    if params["target_months"].present?
      return tool_error("invalid_target_months", "target_months must be a whole number above 0.") unless target_months&.positive?
      return tool_error("target_months_needs_reserve", "target_months is for reserves: pass kind maintained, or a target_amount.") unless kind == "maintained"
    elsif !target_amount&.positive?
      return tool_error("invalid_target_amount", "target_amount must be a number above 0, in the family currency.")
    end

    target_date = nil
    if params["target_date"].present?
      target_date = parse_date(params["target_date"])
      return tool_error("invalid_target_date", "target_date must be a YYYY-MM-DD date.") unless target_date
    end

    account_ids = Array(params["account_ids"]).map(&:to_s).map(&:strip).compact_blank.uniq
    return tool_error("no_accounts", "Pass at least one account id in account_ids.", available_accounts: available_accounts) if account_ids.empty?

    accounts = linkable_accounts.where(id: account_ids.select { |id| valid_uuid?(id) }).index_by { |account| account.id.to_s }
    unknown = account_ids - accounts.keys
    if unknown.any?
      return tool_error("account_not_found", "These ids are not accounts that can fund a goal. Use ids from available_accounts.",
        unknown_account_ids: unknown, available_accounts: available_accounts)
    end

    earmarks, invalid = parse_earmarks(params["earmarks"])
    return tool_error("invalid_earmarks", "earmarks must map account ids from account_ids to amounts above 0.", invalid_account_ids: invalid) if invalid.any? || (earmarks.keys - account_ids).any?

    claimed = account_ids.select { |id| whole_account_claimed_ids.include?(id) && earmarks[id].nil? }
    if claimed.any?
      return tool_error("account_claimed_in_full",
        "Another goal claims these accounts in full. Ask the user how much to reserve from each and pass it in earmarks.",
        claimed_account_ids: claimed, available_accounts: available_accounts)
    end

    goal = family.goals.new(
      name: name,
      kind: kind,
      target_mode: target_months ? "months_of_expenses" : "fixed",
      target_months: target_months,
      target_amount: target_amount,
      target_date: kind == "maintained" ? nil : target_date,
      currency: family.primary_currency_code,
      notes: params["notes"].to_s.strip.presence,
      color: Goal::COLORS.sample
    )

    if target_months && !target_amount && !goal.months_target_derivable?
      return tool_error("no_spending_history", "There is no spending history to size the reserve from yet. Pass a target_amount instead.")
    end

    Goal.transaction do
      account_ids.each { |id| goal.goal_accounts.build(account: accounts[id], allocated_amount: earmarks[id]) }
      goal.save!
    end

    { id: goal.id, created: true, goal: goal_snapshot(goal) }
  rescue ActiveRecord::RecordInvalid => e
    tool_error("validation_failed", e.record.errors.full_messages.to_sentence)
  end

  private
    # The goal form's accounts: active manual accounts of a fundable type. Bank providers stay hidden in this app.
    def linkable_accounts
      family.accounts.counted_in_totals.manual.where(accountable_type: Goal::FUNDABLE_ACCOUNT_TYPES)
    end

    # Accounts a live goal claims in full: another goal can join one only with an earmark
    def whole_account_claimed_ids
      @whole_account_claimed_ids ||= GoalAccount.joins(:goal)
        .where(allocated_amount: nil)
        .where(goals: { family_id: family.id })
        .where.not(goals: { state: Goal::RELEASED_STATES })
        .pluck(:account_id)
        .map(&:to_s)
        .to_set
    end

    # What the model needs to re-ask: each account that can fund a goal, what it has left, and whether it is taken whole
    def available_accounts
      linkable_accounts.alphabetically.map do |account|
        {
          id: account.id,
          name: account.name,
          type: account.accountable_type,
          currency: account.currency,
          free_to_earmark: Money.new(account.free_to_earmark, account.currency).format,
          claimed_in_full: whole_account_claimed_ids.include?(account.id.to_s)
        }
      end
    end

    def goal_snapshot(goal)
      {
        id: goal.id,
        name: goal.name,
        kind: goal.kind,
        target_amount: goal.target_amount.to_d.to_s("F"),
        target_amount_formatted: goal.target_amount_money.format,
        currency: goal.currency,
        target_months: goal.target_months,
        target_date: goal.target_date&.iso8601,
        url: Rails.application.routes.url_helpers.goal_path(goal),
        accounts: goal.goal_accounts.map do |link|
          {
            account_id: link.account_id,
            name: link.account.name,
            earmark: link.allocated_amount&.to_d&.to_s("F"),
            whole_account: link.allocated_amount.nil?
          }
        end
      }
    end

    # Non-positive amounts are refused rather than dropped: a zero earmark and no earmark mean different things
    def parse_earmarks(raw)
      return [ {}, [] ] if raw.blank?
      return [ {}, [ "earmarks" ] ] unless raw.is_a?(Hash)

      invalid = []
      earmarks = raw.each_with_object({}) do |(account_id, amount), result|
        value = parse_decimal(amount)
        value&.positive? ? result[account_id.to_s.strip] = value : invalid << account_id.to_s
      end

      [ earmarks, invalid ]
    end

    def parse_decimal(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # JSON clients may send 6 as 6.0
    def parse_integer(value)
      return nil if value.blank?
      return (value == value.to_i ? value.to_i : nil) if value.is_a?(Numeric)

      Integer(value.to_s, 10)
    rescue ArgumentError, TypeError
      nil
    end

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end
end
