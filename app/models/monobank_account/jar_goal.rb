# A monobank jar's savings target as a Sure goal (owner decision 2026-11-16). Every sync of
# a linked jar with a target keeps one goal for it: named after the jar, with the jar's
# target in the jar's currency, funded by the whole of the jar's Sure account.
#
# What the sync remembers is a MonobankJarGoalLink per family and jar id, so it survives a
# disconnect and reconnect of monobank: the goal, the account it put the goal's link on,
# and the target and title it last took from monobank. A later sync:
#
# - moves the target only when the jar's target changed in monobank since then, so a
#   target the owner set in Sure stays until the jar's own target moves. A target the
#   goal refuses (below what was spent from it) counts as passed: logged once, not retried.
# - renames the goal only while its name is still the last synced title, so the owner's
#   own name stays
# - moves the goal's link to the jar's account when the jar was linked to another Sure
#   account or its account was deleted. A link the owner added to another account stays,
#   and so does the owner taking the jar's account off the goal.
# - leaves a completed or archived goal as it is (it only records what monobank sent)
# - leaves the goal as it is when the jar loses its target; an unlinked or skipped jar is
#   not processed at all, so its goal stays too
# - never makes the goal again once the owner deleted it
#
# A jar whose account already funds another live goal gets no goal: the skip is logged
# (DebugLogEntry), never raised, and the next sync tries again. Skips and errors are
# logged once a day per jar and reason, so the hourly sync does not flood the log.
class MonobankAccount::JarGoal
  LOG_CATEGORY = "monobank_jar_goal"
  ICON = "piggy-bank"
  LOG_THROTTLE = 1.day

  attr_reader :monobank_account, :account, :link

  def initialize(monobank_account, account = monobank_account.current_account)
    @monobank_account = monobank_account
    @account = account
  end

  # :created, :updated, :unchanged, :dismissed or :skipped; nil when there is nothing to do
  # (a card, an unlinked jar, a jar without a target and without a goal)
  def sync
    return nil unless monobank_account.jar? && account

    @link = monobank_account.jar_goal_link
    return nil if link.nil? && monobank_account.jar_target.nil?

    @link ||= MonobankJarGoalLink.create_or_find_by!(family_id: monobank_account.monobank_item.family_id,
                                                     jar_id: monobank_account.account_id)

    # The link row is locked first, then the goal's rows: Goal#destroy takes them in the
    # same order. The lock also keeps two syncs of one jar from both making a goal.
    link.with_lock(requires_new: true) do
      if (goal = link.goal)
        update(goal)
      elsif link.dismissed?
        link.update!(dismissed_at: Time.current) if link.dismissed_at.nil?
        :dismissed
      elsif monobank_account.jar_target
        create
      end
    end
  rescue => e
    log_once("monobank jar goal could not be written", key: e.class.name, level: "error",
             error_class: e.class.name, error_message: e.message)
    :skipped
  end

  private
    def create
      if (reason, metadata = funding_refusal)
        return skip(reason, **metadata)
      end

      target = monobank_account.jar_target
      title = monobank_account.jar_title
      goal = account.family.goals.new(
        name: title.to_s.truncate(255), target_amount: target, currency: monobank_account.currency,
        kind: "one_off", target_mode: "fixed", color: Goal::COLORS.sample,
        icon: (ICON if Goal::ICONS.include?(ICON))
      )
      goal.goal_accounts.build(account: account, allocated_amount: nil)
      goal.save!

      link.update!(goal: goal, funding_account: account, synced_target: target, synced_title: title, dismissed_at: nil)
      :created
    end

    def update(goal)
      target = monobank_account.jar_target
      title = monobank_account.jar_title
      synced = {}
      synced[:synced_target] = target if target && target != link.synced_target
      synced[:synced_title] = title if title.present? && title != link.synced_title

      # A completed or archived goal is closed: it keeps the target it was reached or let
      # go against. Only what monobank sent is recorded, so reopening it replays nothing.
      if Goal::RELEASED_STATES.include?(goal.state)
        if synced.key?(:synced_target)
          log("monobank jar target not applied to a closed goal", level: "info", goal_id: goal.id, goal_state: goal.state)
        end
        link.update!(synced) if synced.any?
        return :unchanged
      end

      moved = fund_from_jar_account(goal)
      return :skipped if moved == :skipped

      # The name and the link go in one save, so a goal left without a link is repaired;
      # the target goes on its own, so a target the goal refuses does not stop a rename
      goal.name = title.truncate(255) if synced.key?(:synced_title) && goal.name == link.synced_title
      changed = moved || goal.name_changed?
      goal.save! if changed
      changed = retarget(goal, target) || changed if synced.key?(:synced_target)

      link.update!(synced.merge(funding_account_id: account.id))
      changed ? :updated : :unchanged
    end

    # The goal is funded by the jar's account. When the jar's account is not the one the
    # sync linked last time (the jar was linked to another Sure account, or its account was
    # deleted), the whole-account link moves to it: the old account's link goes, links the
    # owner added to other accounts stay. When it is the same account and the goal no
    # longer has it, the owner took it off in Sure, and that stays.
    # true when the link moved, false when there was nothing to do, :skipped
    def fund_from_jar_account(goal)
      links = goal.goal_accounts.to_a
      return false if links.any? { |goal_account| goal_account.account_id == account.id }
      return false if link.funding_account_id == account.id && links.any?

      if (other = other_account_of_this_jar)
        return skip("jar is linked to more than one Sure account", other_account_id: other)
      end
      if (reason, metadata = funding_refusal(goal))
        return skip(reason, **metadata)
      end

      links.find { |goal_account| goal_account.account_id == link.funding_account_id }&.mark_for_destruction
      goal.goal_accounts.build(account: account, allocated_amount: nil)
      true
    end

    # A months-of-expenses reserve derives its own target: the jar's is not written. A
    # target the goal refuses is treated like an owner's override: the synced target still
    # moves, so it is not tried again until monobank's target changes.
    def retarget(goal, target)
      return false unless goal.target_mode == "fixed"
      return false if goal.target_amount.to_d == target.to_d
      return true if goal.update(target_amount: target)
      raise ActiveRecord::RecordInvalid, goal unless goal.errors.include?(:target_amount)

      log("monobank jar target refused by the goal", level: "warn", goal_id: goal.id,
          errors: goal.errors.full_messages)
      goal.restore_attributes([ :target_amount ])
      false
    end

    # [reason, metadata] when the jar's account cannot fund a goal of this jar
    def funding_refusal(goal = nil)
      unless Goal::FUNDABLE_ACCOUNT_TYPES.include?(account.accountable_type)
        return [ "jar account cannot fund a goal", { accountable_type: account.accountable_type } ]
      end

      claim = other_goal_claim(goal)
      [ "jar account already funds another goal", { other_goal_id: claim.goal_id, other_goal_name: claim.goal.name } ] if claim
    end

    # A link to this account from another goal that has not let go of its money
    def other_goal_claim(goal)
      claims = GoalAccount.joins(:goal).includes(:goal)
                          .where(account_id: account.id, goals: { family_id: account.family_id })
                          .where.not(goals: { state: Goal::RELEASED_STATES })
      claims = claims.where.not(goal_id: goal.id) if goal
      claims.first
    end

    # The account the goal is on now, while it is still linked to this jar through another
    # monobank connection of the family (the same token connected twice): moving the goal
    # there and back on every sync helps nobody
    def other_account_of_this_jar
      return nil if link.funding_account_id.nil? || link.funding_account_id == account.id

      same_jar = MonobankAccount.joins(:monobank_item)
                                .where(account_id: monobank_account.account_id, monobank_items: { family_id: link.family_id })
                                .where.not(id: monobank_account.id)
      AccountProvider.where(account_id: link.funding_account_id, provider_type: "MonobankAccount", provider_id: same_jar.select(:id))
                     .pick(:account_id)
    end

    def skip(reason, **metadata)
      log_once("monobank jar goal skipped: #{reason}", key: reason, level: "info", reason: reason, **metadata)
      :skipped
    end

    # Once a day per jar and key: the hourly sync meets the same skip or error again
    def log_once(message, key:, level:, **metadata)
      jar = link&.id || monobank_account.id
      return unless Rails.cache.write([ "monobank_jar_goal_log", jar, key ], true, expires_in: LOG_THROTTLE, unless_exist: true)

      log(message, level: level, **metadata)
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
