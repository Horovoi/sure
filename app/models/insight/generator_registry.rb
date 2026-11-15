# Runs every insight generator for a family. A generator that raises is written to
# the super-admin debug log and skipped, so one bad signal never blocks the rest. The
# result names the kinds whose generator completed: the job clears stale insights of
# those kinds only, so a crashing generator can never wipe out its own insights.
class Insight::GeneratorRegistry
  # Each unit adds its generators in its own block
  def self.generators
    [
      # insights-feed (w3-reports)
      Insight::Generators::SpendingAnomalyGenerator,
      Insight::Generators::CashFlowWarningGenerator,
      Insight::Generators::NetWorthMilestoneGenerator,
      Insight::Generators::SavingsRateChangeGenerator,
      Insight::Generators::IdleCashGenerator,
      Insight::Generators::BudgetInsightGenerator
    ]
  end

  Result = Data.define(:insights, :succeeded_kinds)

  def initialize(family)
    @family = family
  end

  def generate_all
    insights = []
    succeeded_kinds = []

    self.class.generators.each do |generator_class|
      insights.concat(generator_class.new(family).generate)
      succeeded_kinds.concat(generator_class.produced_kinds)
    rescue => e
      DebugLogEntry.capture(
        category: "insights",
        level: "error",
        message: "#{generator_class.name} failed: #{e.class}: #{e.message}",
        source: self.class.name,
        family: family,
        metadata: { generator: generator_class.name, backtrace: e.backtrace&.first(5) }
      )
    end

    Result.new(insights: insights, succeeded_kinds: succeeded_kinds)
  end

  private
    attr_reader :family
end
