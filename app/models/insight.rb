# A typed observation about the family's finances, written nightly by
# GenerateInsightsJob (decision 37). The financial logic lives in
# Insight::Generators::*. No prose is stored and no LLM is called: the title and the
# body are English locale templates (insights.titles / insights.templates) filled with
# the row's `facts` when the feed renders.
#
# Dismissing hides the numbers the user saw. When a later run finds the numbers
# changed materially (`metadata` differs), the insight comes back; the same numbers
# never do. A new fiscal month is a new row (period_start), so dismissing October's
# budget warning says nothing about November's.
class Insight < ApplicationRecord
  belongs_to :family

  KINDS = %w[
    budget_at_risk
    budget_on_track
    cash_flow_warning
    idle_cash
    net_worth_milestone
    savings_rate_change
    spending_anomaly
    maintained_goal_depleted
  ].freeze

  PRIORITIES = %w[high medium low].freeze

  # How many the dashboard section shows. Shared by PagesController (first render) and
  # InsightsController (re-render after a dismiss or an undo).
  FEED_LIMIT = 3

  validates :kind, inclusion: { in: KINDS }
  validates :priority, inclusion: { in: PRIORITIES }
  validates :dedupe_key, :template_key, :generated_at, presence: true
  # Mirrors the unique index, so a direct caller gets a validation error; races still
  # hit the index (GenerateInsightsJob rescues that)
  validates :dedupe_key, uniqueness: { scope: %i[family_id kind period_start] }

  scope :visible, -> { where(dismissed_at: nil) }
  scope :dismissed, -> { where.not(dismissed_at: nil) }
  scope :ordered, -> {
    order(Arel.sql("CASE insights.priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END"))
      .order(generated_at: :desc, id: :asc)
  }

  def title
    I18n.t("insights.titles.#{template_key}", **interpolation_facts)
  end

  def body
    I18n.t("insights.templates.#{template_key}", **interpolation_facts)
  end

  def dismissed?
    dismissed_at.present?
  end

  def dismiss!
    update!(dismissed_at: Time.current) unless dismissed?
  end

  # Only reverses a real dismissal, so a stale undo link does nothing
  def undismiss!
    update!(dismissed_at: nil) if dismissed?
  end

  # The fiscal period the insight is about, or nil for one without a period
  def period
    return nil unless period_start

    Period.custom(start_date: period_start, end_date: family.budget_period_end_for(period_start))
  end

  private
    # I18n takes symbol keys; `count` stays numeric so pluralized templates work
    def interpolation_facts
      (facts || {}).to_h.symbolize_keys
    end
end
