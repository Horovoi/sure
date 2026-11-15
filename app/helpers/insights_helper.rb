module InsightsHelper
  INSIGHT_ICONS = {
    "spending_anomaly" => "activity",
    "cash_flow_warning" => "triangle-alert",
    "net_worth_milestone" => "trophy",
    "savings_rate_change" => "piggy-bank",
    "idle_cash" => "wallet",
    "budget_at_risk" => "triangle-alert",
    "budget_on_track" => "circle-check",
    "maintained_goal_depleted" => "shield-alert"
  }.freeze

  # Numeric fragments inside insight prose: amounts ("₴1,234.56", "1 234,56 €"),
  # percentages and counts. They start and end on a digit, so punctuation stays out.
  INSIGHT_NUMERIC_FRAGMENT = /
    (?:\p{Sc}[\s  ]?)?
    [−-]?\d(?:[\d.,\s  ]*\d)?
    (?:[\s  ]?(?:%|\p{Sc}))?
  /x

  def insight_icon_key(insight)
    INSIGHT_ICONS.fetch(insight.kind, "lightbulb")
  end

  # The text is rendered from templates with the amounts already in it, so the numbers
  # cannot be tagged where they are formatted. Each numeric fragment is wrapped in a
  # privacy-sensitive span instead, so privacy mode blurs the figures and keeps the
  # sentence readable.
  def insight_privacy_text(text)
    safe_join(
      text.to_s.split(/(#{INSIGHT_NUMERIC_FRAGMENT})/o).map.with_index do |part, index|
        index.odd? ? tag.span(part, class: "privacy-sensitive") : part
      end
    )
  end

  # "Spending · November 2026": the kind and the fiscal period it is about
  def insight_meta_line(insight)
    parts = [ t("insights.kinds.#{insight.kind}") ]
    parts << insight_period_label(insight)
    parts.compact.join(" · ")
  end

  # [value, caption] for the right-aligned key figure, or nil
  def insight_key_figure(insight)
    facts = insight.facts || {}

    case insight.kind
    when "savings_rate_change"
      return nil unless facts["change_pp"]

      sign = insight_sentiment(insight) == :positive ? "+" : "−"
      [ t("insights.figures.points", value: "#{sign}#{facts["change_pp"]}"), t("insights.figures.vs_previous") ]
    when "net_worth_milestone"
      facts["net_worth"] && [ facts["net_worth"], t("insights.figures.today") ]
    when "spending_anomaly"
      facts["spent"] && [ facts["spent"], t("insights.figures.so_far") ]
    when "cash_flow_warning"
      facts["projected_low"] && [ facts["projected_low"], facts["projected_low_date"] ]
    when "idle_cash"
      facts["balance"] && [ facts["balance"], t("insights.figures.idle_days", count: facts["idle_days"].to_i) ]
    when "budget_at_risk"
      facts["count"] && [ facts["count"].to_s, t("insights.figures.need_attention") ]
    when "budget_on_track"
      facts["budget_spent_pct"] && [ "#{facts["budget_spent_pct"]}%", t("insights.figures.of_budget") ]
    when "maintained_goal_depleted"
      facts["missing"] && [ facts["missing"], t("insights.figures.short") ]
    end
  end

  # The link to the insight's subject, from the ids in its metadata. Nil when the
  # subject is gone (a deleted category, account or goal).
  def insight_action(insight)
    metadata = insight.metadata || {}
    period = insight.period

    case insight.kind
    when "spending_anomaly"
      category = insight.family.categories.find_by(id: metadata["category_id"])
      category && period && {
        text: t("insights.actions.spending_anomaly", category: category.name),
        href: transactions_path(q: { categories: [ category.filter_value ], start_date: period.start_date, end_date: Date.current })
      }
    when "idle_cash"
      account = insight.family.accounts.visible.find_by(id: metadata["account_id"])
      account && { text: t("insights.actions.idle_cash"), href: account_path(account) }
    when "cash_flow_warning"
      { text: t("insights.actions.cash_flow_warning"), href: subscriptions_path }
    when "savings_rate_change"
      period && {
        text: t("insights.actions.savings_rate_change"),
        href: transactions_path(q: { start_date: period.start_date, end_date: period.end_date })
      }
    when "net_worth_milestone"
      { text: t("insights.actions.net_worth_milestone"), href: reports_path }
    when "budget_at_risk", "budget_on_track"
      metadata["budget_param"].present? && { text: t("insights.actions.budget"), href: budget_path(metadata["budget_param"]) }
    when "maintained_goal_depleted"
      goal = insight.family.goals.find_by(id: metadata["goal_id"])
      goal && { text: t("insights.actions.maintained_goal_depleted"), href: goal_path(goal) }
    end
  end

  # "Dig in with AI" opens a new chat in the sidebar with this message in the box. The
  # chat runs on the model Settings picks (Claude through the bridge, or OpenAI) with
  # every tool, like any chat, and each tool call is audited.
  def insight_dig_in_available?
    Current.user&.ai_enabled?
  end

  def insight_dig_in_prompt(insight)
    period = insight.period
    facts = (insight.facts || {}).map { |key, value| "- #{key.to_s.humanize}: #{value}" }.join("\n")

    t(
      "insights.dig_in.prompt",
      title: insight.title,
      body: insight.body,
      period: period ? t("insights.meta.date_range", from: l(period.start_date, format: :long), to: l(period.end_date, format: :long)) : t("insights.dig_in.no_period"),
      facts: facts.presence || t("insights.dig_in.no_facts")
    )
  end

  # The colour follows the sentiment; the priority only orders the feed. A big rise in
  # the savings rate is high priority and good news, and must not render red.
  def insight_icon_css_color(insight)
    case insight_sentiment(insight)
    when :positive then "var(--color-success)"
    when :negative then "var(--color-destructive)"
    when :warning then "var(--color-warning)"
    else "var(--color-gray-500)"
    end
  end

  def insight_sentiment(insight)
    metadata = insight.metadata || {}

    case insight.kind
    when "net_worth_milestone", "budget_on_track"
      :positive
    when "savings_rate_change"
      metadata["current_rate"].to_f >= metadata["previous_rate"].to_f ? :positive : :warning
    when "spending_anomaly"
      metadata["direction"] == "below" ? :positive : :warning
    when "cash_flow_warning"
      metadata["negative"] ? :negative : :warning
    when "budget_at_risk", "maintained_goal_depleted"
      :warning
    else
      :neutral
    end
  end

  private
    def insight_period_label(insight)
      return nil unless insight.period_start

      if insight.kind == "cash_flow_warning"
        t("insights.meta.next_n_days", count: (insight.facts || {})["horizon_days"].to_i)
      else
        I18n.l(insight.period_start, format: "%B %Y")
      end
    end
end
