# Writes the insights feed. Nightly from config/schedule.yml without arguments: one
# job per family. With a family: runs every generator and upserts the results.
#
# The family is the first argument, so ApplicationJob runs it in the family's time zone
# (Family#resolved_time_zone, Kyiv here): "today" and the fiscal month are the family's.
#
# Idempotent: a row is keyed by kind, dedupe_key and period_start (a unique index), so
# a second run on the same day updates rows and adds none. No LLM call (decision 37).
class GenerateInsightsJob < ApplicationJob
  queue_as :scheduled

  # Dismissed rows of periods this far back are no longer shown or compared, so they go
  PRUNE_DISMISSED_AFTER_PERIODS = 2

  def perform(family = nil)
    family ? generate_for(family) : fan_out
  end

  private
    def fan_out
      Family.find_each { |family| self.class.perform_later(family) }
    end

    def generate_for(family)
      return if family.accounts.none?

      ran = with_advisory_lock("generate_insights:#{family.id}") do
        result = Insight::GeneratorRegistry.new(family).generate_all
        upsert(family, result.insights)
        clear_stale(family, result)
        prune_dismissed(family)
      end

      Rails.logger.warn("GenerateInsightsJob: skipped family #{family.id}, another run holds the lock") unless ran
    end

    def upsert(family, generated_insights)
      generated_insights.each do |generated|
        upsert_one(family, generated)
      rescue ActiveRecord::RecordNotUnique
        # A concurrent run created the same row first; it owns it
        nil
      rescue => e
        DebugLogEntry.capture(
          category: "insights",
          level: "error",
          message: "Could not save insight #{generated.kind}/#{generated.dedupe_key}: #{e.class}: #{e.message}",
          source: self.class.name,
          family: family,
          metadata: { kind: generated.kind, dedupe_key: generated.dedupe_key }
        )
      end
    end

    def upsert_one(family, generated)
      facts = normalize_json(generated.facts)
      metadata = normalize_json(generated.metadata)
      attributes = {
        priority: generated.priority,
        template_key: generated.template_key,
        facts: facts,
        metadata: metadata,
        generated_at: Time.current
      }

      existing = family.insights.find_by(kind: generated.kind, dedupe_key: generated.dedupe_key, period_start: generated.period_start)

      if existing.nil?
        family.insights.create!(attributes.merge(kind: generated.kind, dedupe_key: generated.dedupe_key, period_start: generated.period_start))
      elsif existing.metadata != metadata
        # The numbers changed materially: the insight comes back even if the user
        # dismissed the version they saw
        existing.update!(attributes.merge(dismissed_at: nil))
      else
        # Same signal, same numbers: refresh the display values, keep the dismissal
        existing.update!(attributes)
      end
    end

    # A visible insight whose generator completed but did not emit it again has had its
    # condition clear, so it goes. A dismissed one stays, so the same numbers never come
    # back. Kinds whose generator failed are left alone.
    def clear_stale(family, result)
      emitted = result.insights.map { |generated| [ generated.kind, generated.dedupe_key, generated.period_start ] }.to_set

      family.insights.visible.where(kind: result.succeeded_kinds).find_each do |insight|
        insight.destroy unless emitted.include?([ insight.kind, insight.dedupe_key, insight.period_start ])
      end
    end

    def prune_dismissed(family)
      cutoff = family.budget_period_start_for(Date.current)
      PRUNE_DISMISSED_AFTER_PERIODS.times { cutoff = family.budget_period_start_for(cutoff - 1.day) }

      family.insights.dismissed.where(period_start: ...cutoff).delete_all
    end

    # Generated facts and metadata may hold symbols, dates or BigDecimals; the jsonb
    # columns hold JSON primitives. Compare like with like, or every run reads as a change.
    def normalize_json(hash)
      JSON.parse(hash.to_json)
    end
end
