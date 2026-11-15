# "Apply all" on the rules page: every active rule, top to bottom, with attribute
# locks ignored (user locks still hold). Inactive rules are drafts or rules the user
# turned off, so they are skipped, as in the post-sync run. A thin wrapper around
# ApplyRulesJob, kept so jobs queued before the ordered runner still run.
class ApplyAllRulesJob < ApplicationJob
  queue_as :medium_priority

  def perform(family, execution_type: "manual")
    ApplyRulesJob.perform_now(family, execution_type: execution_type, ignore_attribute_locks: true)
  end
end
