# Insights feed (w3-reports insights-feed). Fork-native, in place of upstream's two
# migrations. GenerateInsightsJob writes one row per signal; the text is rendered from
# the English locale templates with `facts`, so no prose is stored.
#
# A row is one signal for one subject in one fiscal period: kind (the generator's
# signal), dedupe_key (its subject: a category, an account, a goal, a milestone) and
# period_start (the fiscal month it is about, or NULL for a signal with no period,
# such as a net-worth milestone). The unique index makes the nightly upsert idempotent.
# NULLS NOT DISTINCT, so two NULL periods are one row (Postgres 15 and later).
class CreateInsights < ActiveRecord::Migration[8.1]
  def change
    create_table :insights, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: false
      t.string :kind, null: false
      t.string :dedupe_key, null: false
      t.date :period_start
      # high, medium or low: orders the feed
      t.string :priority, null: false, default: "medium"
      # The locale key under insights.titles and insights.templates (a kind can have
      # variants, such as spending above or below normal)
      t.string :template_key, null: false
      # Display values for the templates (formatted amounts, names, percentages)
      t.jsonb :facts, null: false, default: {}
      # The values a later run compares to decide that the numbers changed materially
      # (bucketed, so daily drift does not count), and the subject ids for links
      t.jsonb :metadata, null: false, default: {}
      t.datetime :dismissed_at
      t.datetime :generated_at, null: false

      t.timestamps
    end

    add_index :insights, %i[family_id kind dedupe_key period_start],
      unique: true, nulls_not_distinct: true, name: "index_insights_on_family_kind_dedupe_key_period"

    add_check_constraint :insights, "priority IN ('high','medium','low')", name: "chk_insights_priority_enum"
  end
end
