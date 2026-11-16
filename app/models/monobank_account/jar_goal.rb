# A monobank jar's savings target as a Sure goal (owner decision 2026-11-16). Every sync of
# a linked jar with a target keeps one goal for it: named after the jar, with the jar's
# target in the jar's currency, funded by the whole of the jar's Sure account.
#
# The jar remembers its goal (goal_id) and what the last sync wrote to it
# (goal_synced_target, goal_synced_title). A later sync:
#
# - moves the target only when the jar's target changed in monobank since then, so a
#   target the owner set in Sure stays until the jar's own target moves
# - renames the goal only while its name is still the last synced title, so the owner's
#   own name stays
# - leaves the goal as it is when the jar loses its target; an unlinked or skipped jar is
#   not processed at all, so its goal stays too
# - never makes the goal again once the owner deleted it (goal_dismissed_at)
#
# A jar whose account already funds another live goal gets no goal: the skip is logged
# (DebugLogEntry), never raised, and the next sync tries again.
class MonobankAccount::JarGoal
  LOG_CATEGORY = "monobank_jar_goal"
  ICON = "piggy-bank"

  attr_reader :monobank_account, :account

  def initialize(monobank_account, account = monobank_account.current_account)
    @monobank_account = monobank_account
    @account = account
  end

  # :created, :updated, :unchanged, :dismissed or :skipped; nil when there is nothing to do
  # (a card, an unlinked jar, a jar without a target and without a goal)
  def sync
    return nil unless monobank_account.jar? && account

    # Locked, so two syncs of one jar cannot both make a goal
    monobank_account.with_lock do
      if (goal = monobank_account.linked_goal)
        update(goal)
      elsif dismissed?
        monobank_account.update!(goal_dismissed_at: Time.current) if monobank_account.goal_dismissed_at.nil?
        :dismissed
      elsif monobank_account.jar_target
        create
      end
    end
  rescue => e
    log("monobank jar goal could not be written", level: "error",
        error_class: e.class.name, error_message: e.message)
    :skipped
  end

  private
    # A goal was made once (the synced target is set only then) and is gone now: the owner
    # deleted it, and the foreign key cleared the link
    def dismissed?
      monobank_account.goal_dismissed_at.present? || monobank_account.goal_synced_target.present?
    end

    def create
      target = monobank_account.jar_target
      title = monobank_account.jar_title

      unless Goal::FUNDABLE_ACCOUNT_TYPES.include?(account.accountable_type)
        return skip("jar account cannot fund a goal", accountable_type: account.accountable_type)
      end

      if (claim = other_goal_claim)
        return skip("jar account already funds another goal", other_goal_id: claim.goal_id, other_goal_name: claim.goal.name)
      end

      goal = account.family.goals.new(
        name: title.to_s.truncate(255), target_amount: target, currency: monobank_account.currency,
        kind: "one_off", target_mode: "fixed", color: Goal::COLORS.sample,
        icon: (ICON if Goal::ICONS.include?(ICON))
      )
      goal.goal_accounts.build(account: account, allocated_amount: nil)
      goal.save!

      monobank_account.update!(goal_id: goal.id, goal_synced_target: target, goal_synced_title: title, goal_dismissed_at: nil)
      :created
    end

    def update(goal)
      target = monobank_account.jar_target
      title = monobank_account.jar_title
      goal_changes = {}
      synced = {}

      if target && target != monobank_account.goal_synced_target
        # A months-of-expenses reserve derives its own target: the jar's is not written
        goal_changes[:target_amount] = target if goal.target_mode == "fixed"
        synced[:goal_synced_target] = target
      end

      if title.present? && title != monobank_account.goal_synced_title
        goal_changes[:name] = title.truncate(255) if goal.name == monobank_account.goal_synced_title
        synced[:goal_synced_title] = title
      end

      return :unchanged if synced.empty?

      goal.update!(goal_changes) if goal_changes.any?
      monobank_account.update!(synced)
      goal_changes.any? ? :updated : :unchanged
    end

    # A link to this account from another goal that has not let go of its money
    def other_goal_claim
      GoalAccount.joins(:goal).includes(:goal)
                 .where(account_id: account.id, goals: { family_id: account.family_id })
                 .where.not(goals: { state: Goal::RELEASED_STATES })
                 .first
    end

    # Logged once a day per jar and reason: the hourly sync meets the same skip again
    def skip(reason, **metadata)
      if Rails.cache.write([ "monobank_jar_goal_skip", monobank_account.id, reason ], true, expires_in: 1.day, unless_exist: true)
        log("monobank jar goal skipped: #{reason}", level: "info", reason: reason, **metadata)
      end
      :skipped
    end

    def log(message, level:, **metadata)
      DebugLogEntry.capture(
        category: LOG_CATEGORY, level: level, message: message, source: self.class.name,
        provider_key: "monobank", family: account&.family, account: account,
        metadata: { monobank_account_id: monobank_account.id, jar: monobank_account.account_id,
                    jar_title: monobank_account.jar_title, jar_target: monobank_account.jar_target&.to_s }.merge(metadata)
      )
    end
end
