# Savings goals (w2-goals), with spending and pledges. Ported from upstream without the
# preview gate and account sharing: one family, so the linkable accounts are the
# family's active manual accounts of a fundable type. The goals live under the Plan page.
class GoalsController < ApplicationController
  before_action :set_goal, only: %i[show edit update destroy pause resume complete archive unarchive reopen consume record_consumption]

  rescue_from ActiveRecord::RecordNotFound, with: :goal_not_found

  STATE_FILTERS = %w[all active paused completed archived].freeze
  PERMITTED_ATTRIBUTES = %i[name target_amount target_date color icon notes kind target_mode target_months].freeze

  def index
    state_counts = Current.family.goals.group(:state).count
    @counts = STATE_FILTERS.index_with do |state|
      state == "all" ? state_counts.values.sum : state_counts.fetch(state, 0)
    end

    all_goals = Goal.prepared_for(Current.family)
    @active_goals = Goal.active_display_sort(all_goals.reject { |goal| goal.state.in?(Goal::RELEASED_STATES) })
    @completed_goals = all_goals.select(&:completed?).sort_by { |goal| goal.name.downcase }
    @archived_goals = all_goals.select(&:archived?)
    # Completed goals join the filterable grid so the "completed" chip can show them;
    # archived ones have their own collapsed section outside the filter
    @grid_goals = @active_goals + @completed_goals

    @linkable_account_count = linkable_accounts_scope.count
    @kpi = kpi_payload(@active_goals)
    @any_pending_pledge = @active_goals.any? { |goal| goal.open_pledges.any? }
    @show_search = @grid_goals.size > 6
    @breadcrumbs = plan_breadcrumbs([ t(".title"), nil ])
  end

  def show
    @open_pledges = @goal.open_pledges.sort_by(&:created_at).reverse
    @unattributed_outflows = withdrawal_detector.unattributed_outflows.to_a
    @breadcrumbs = plan_breadcrumbs([ t("goals.index.title"), goals_path ], [ @goal.name, nil ])
  end

  def new
    @goal = Current.family.goals.new(color: Goal::COLORS.sample, currency: Current.family.primary_currency_code)
    prepare_form
    @currently_linked_account_ids = []
    @return_to = sanitize_return_to(params[:return_to])
  end

  def create
    @goal = Current.family.goals.new(goal_params)
    # The family currency is what the form shows next to the target
    @goal.currency = Current.family.primary_currency_code if @goal.currency.blank?

    allocations = submitted_allocations
    Goal.transaction do
      lookup_accounts(params.dig(:goal, :account_ids)).each do |account|
        @goal.goal_accounts.build(account: account, allocated_amount: allocations[account.id.to_s])
      end
      @goal.save!
    end

    # A goal made from the Plan page goes back there; otherwise to the new goal
    redirect_after_save(t(".success"), to: sanitize_return_to(params[:return_to]))
  rescue ActiveRecord::RecordInvalid
    @return_to = sanitize_return_to(params[:return_to])
    prepare_form
    # From the built links: nothing is saved yet, so a query would uncheck every box
    @currently_linked_account_ids = @goal.goal_accounts.map { |link| link.account_id.to_s }
    render :new, status: :unprocessable_entity
  end

  def edit
    prepare_form
    @currently_linked_account_ids = linked_account_id_strings
  end

  def update
    account_ids = params.dig(:goal, :account_ids)
    accounts_supplied = !account_ids.nil?
    accounts = accounts_supplied ? lookup_accounts(account_ids) : []

    if accounts_supplied && accounts.empty?
      @goal.assign_attributes(goal_params)
      @goal.errors.add(:base, :at_least_one_linked_account_required)
      render_edit_with_errors
      return
    end

    # Assign, sync the links, then save once, so the validations see what was submitted
    # (a goal left without links by an account deletion can be edited back to health)
    Goal.transaction do
      @goal.assign_attributes(goal_params)
      if accounts_supplied
        sync_linked_accounts!(@goal, accounts, submitted_allocations)
      else
        @goal.save!
      end
    end

    redirect_after_save(t(".success"))
  rescue ActiveRecord::RecordInvalid
    render_edit_with_errors
  end

  # Allowed in any state: only the goal, its account links and its pledges go (a kept
  # pledge's id is taken off its transaction). Accounts, balances and transactions stay.
  def destroy
    @goal.destroy!
    redirect_to goals_path, notice: t(".success")
  end

  def pause = perform_transition!(:pause)
  def resume = perform_transition!(:resume)
  def complete = perform_transition!(:complete)
  def archive = perform_transition!(:archive)
  def unarchive = perform_transition!(:unarchive)
  def reopen = perform_transition!(:reopen)

  # The spend dialog (goal-spending), rendered into the modal frame
  def consume
    @consumption_accounts = consumption_accounts
  end

  # A typed spend, or an outflow from the goal page's list. An outflow says both how
  # much and from where, so neither is read from the form for it.
  def record_consumption
    txn = consumption_transaction
    amount = txn ? @goal.convert_money!(txn.entry.amount_money, date: txn.entry.date).amount : params[:amount].to_s.strip.to_d

    @goal.consume!(amount, account: consumption_account(txn), transaction: txn)
    redirect_to goal_path(@goal), notice: t("goals.consume.success", amount: Money.new(amount, @goal.currency).format)
  rescue Money::ConversionError
    redirect_to goal_path(@goal), alert: t("goals.consume.errors.missing_exchange_rate")
  rescue Goal::ConsumptionRefused => e
    redirect_to goal_path(@goal), alert: t("goals.consume.errors.#{e.reason}")
  rescue ActiveRecord::RecordInvalid => e
    redirect_to goal_path(@goal), alert: e.record.errors.full_messages.to_sentence
  end

  private
    def set_goal
      @goal = Current.family.goals.includes(:goal_accounts, :open_pledges, linked_accounts: :account_providers).find(params[:id])
    end

    # ---- spending ----

    # One family: every linked account is the reader's
    def consumption_accounts
      @goal.linked_accounts.to_a
    end

    def withdrawal_detector
      Goal::WithdrawalDetector.new(@goal, accounts: consumption_accounts)
    end

    # Only an outflow the goal page could list may be attributed
    def consumption_transaction
      return nil if params[:transaction_id].blank?

      withdrawal_detector.unattributed_outflows(limit: 50).find_by(entryable_id: params[:transaction_id])&.entryable ||
        raise(Goal::ConsumptionRefused.new(:transaction_not_found))
    end

    # An outflow names its own account; a typed spend names one only when the goal has
    # several to choose from
    def consumption_account(txn = nil)
      account_id = txn ? txn.entry.account_id : params[:account_id]
      return nil if account_id.blank?

      consumption_accounts.find { |account| account.id.to_s == account_id.to_s } ||
        raise(Goal::ConsumptionRefused.new(:account_not_linked))
    end

    def goal_not_found
      redirect_to goals_path, alert: t("goals.errors.not_found")
    end

    def goal_params
      params.expect(goal: PERMITTED_ATTRIBUTES)
    end

    def linkable_accounts_scope
      Goal.linkable_accounts_for(Current.family)
    end

    # Goals live under the Plan page
    def set_breadcrumbs
      @breadcrumbs = plan_breadcrumbs([ t("goals.index.title"), goals_path ])
    end

    def lookup_accounts(ids)
      ids = Array(ids).compact_blank
      return [] if ids.empty?

      linkable_accounts_scope.where(id: ids).to_a
    end

    def prepare_form
      @linkable_accounts = linkable_accounts_scope.alphabetically.to_a
      @pooled_allocations = Goal.pooled_allocations_for(Current.family)
    end

    def linked_account_id_strings
      @goal.goal_accounts.reject(&:marked_for_destruction?).map { |link| link.account_id.to_s }
    end

    def render_edit_with_errors
      prepare_form
      @currently_linked_account_ids = linked_account_id_strings
      render :edit, status: :unprocessable_entity
    end

    def redirect_after_save(notice, to: nil)
      flash[:notice] = notice
      target = to || goal_path(@goal)
      respond_to do |format|
        format.html { redirect_to target }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, target) }
      end
    end

    def sync_linked_accounts!(goal, accounts, allocations = {})
      desired_ids = accounts.map(&:id).to_set

      # Only links the picker shows can be removed: a link to an account that is no
      # longer linkable (disabled, or provider-linked) never renders as a checkbox, so
      # its absence from the form is not a removal
      removable_ids = linkable_accounts_scope.where(id: goal.goal_accounts.map(&:account_id)).pluck(:id).to_set

      goal.goal_accounts.each do |link|
        link.mark_for_destruction if removable_ids.include?(link.account_id) && !desired_ids.include?(link.account_id)
      end

      # New links are built; kept links get the submitted earmark only when the form
      # sent one for that account. Saved through the goal, so its validations run.
      accounts.each do |account|
        key = account.id.to_s
        existing = goal.goal_accounts.find { |link| link.account_id == account.id }
        if existing
          existing.allocated_amount = allocations[key] if allocations.key?(key)
        else
          goal.goal_accounts.build(account: account, allocated_amount: allocations[key])
        end
      end

      goal.save!
    end

    # { account_id => amount or nil } from goal[allocations]. A blank amount means the
    # whole balance (NULL allocated_amount).
    def submitted_allocations
      raw = params.dig(:goal, :allocations)
      return {} unless raw.respond_to?(:permit)

      raw.permit(*raw.keys).to_h.each_with_object({}) do |(account_id, amount), memo|
        memo[account_id.to_s] = amount.to_s.strip.presence
      end
    end

    def perform_transition!(event)
      unless @goal.aasm.may_fire_event?(event)
        redirect_to goal_path(@goal), alert: t(".invalid_transition")
        return
      end

      begin
        @goal.public_send("#{event}!")
      rescue ActiveRecord::RecordInvalid
        # whiny_persistence: a validation (an orphaned goal, a whole-account conflict on
        # restore, a missing rate on complete) refused the save; the state did not move
        redirect_to goal_path(@goal), alert: @goal.errors.full_messages.to_sentence.presence || t(".invalid_transition")
        return
      end

      respond_to do |format|
        format.html { redirect_to goal_path(@goal), notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, goal_path(@goal)) }
      end
    end

    def kpi_payload(active_goals)
      currency = Current.family.primary_currency_code
      windows = Goal.inflow_windows_for(Current.family, window_days: 30)
      velocity_30d = windows[:current]
      velocity_prior_30d = windows[:prior]
      delta_amount = velocity_30d - velocity_prior_30d
      delta_percent = velocity_prior_30d.zero? ? nil : ((delta_amount / velocity_prior_30d.abs) * 100).round(1)

      delta_direction = if delta_amount.positive? then :up
      elsif delta_amount.negative? then :down
      else :flat
      end

      behind_goals = active_goals.select(&:behind_pace?)
      tracked = active_goals.reject { |goal| goal.paused? || goal.maintained? }

      {
        currency: currency,
        velocity_30d_money: Money.new(velocity_30d.abs, currency),
        velocity_prior_30d_money: Money.new(velocity_prior_30d.abs, currency),
        # The sign shows this window's direction; the delta line says up or down
        velocity_30d_sign: velocity_30d.negative? ? "−" : "",
        velocity_delta_percent: delta_percent,
        velocity_direction: delta_direction,
        needs_this_month_money: Money.new(needs_this_month(behind_goals, currency), currency),
        on_track_count: tracked.count { |goal| goal.status == :on_track },
        reached_count: active_goals.count { |goal| goal.status == :reached },
        behind_count: behind_goals.size,
        no_date_count: active_goals.count { |goal| goal.status == :no_target_date },
        paused_count: active_goals.count(&:paused?),
        # Goals with a pace to compare against: not reached, not open-ended, not paused,
        # not a reserve
        tracked_total: tracked.count { |goal| goal.status.in?(%i[on_track behind]) },
        active_total: active_goals.size
      }
    end

    # Sum of what the behind goals need per month, in family currency. A goal in another
    # currency is converted; one without a rate is left out.
    def needs_this_month(behind_goals, currency)
      behind_goals.sum do |goal|
        monthly = Money.new(goal.monthly_target_amount.to_d, goal.currency)
        converted = ExchangeRate.convert_or_leave_out(monthly, to: currency, source: "GoalsController#kpi", family: Current.family)
        converted ? converted.amount.to_d : 0.to_d
      end
    end
end
