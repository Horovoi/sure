# Pledges on a goal (w2-goals goal-pledges, ported from upstream without the preview
# gate). A pledge is the user saying "I just put X in"; GoalPledge::Reconciler keeps it
# when the deposit, transfer or balance update is recorded.
class GoalPledgesController < ApplicationController
  before_action :set_goal
  before_action :set_pledge, only: %i[renew destroy]

  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def new
    # The form is a dialog. A direct GET (a reload, a stale link) goes back to the goal
    # page instead of drawing a dialog over nothing.
    return redirect_to(goal_path(@goal)) unless turbo_frame_request?

    @pledge = @goal.goal_pledges.new(account: preselected_account, amount: params[:amount].presence)
  end

  def create
    @pledge = @goal.goal_pledges.new(pledge_params.except(:account_id))
    # Only one of the goal's own accounts; the kind and currency come from it and the goal
    @pledge.account = @goal.linked_accounts.find_by(id: pledge_params[:account_id])
    @pledge.currency = @goal.currency

    if @pledge.save
      flash[:notice] = t(".success")
      respond_to do |format|
        format.html { redirect_to goal_path(@goal) }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, goal_path(@goal)) }
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def renew
    @pledge.extend!
    redirect_to goal_path(@goal), notice: t(".success")
  rescue GoalPledge::NotOpenError
    redirect_to goal_path(@goal), alert: t(".not_open")
  end

  # Cancels, keeping the row: a cancelled pledge is history, not an error
  def destroy
    @pledge.with_lock do
      raise GoalPledge::NotOpenError unless @pledge.may_cancel?

      @pledge.cancel!
    end
    redirect_to goal_path(@goal), notice: t(".success")
  rescue GoalPledge::NotOpenError
    redirect_to goal_path(@goal), alert: t(".not_open")
  end

  private
    def set_goal
      @goal = Current.family.goals.includes(:goal_accounts, :open_pledges, linked_accounts: :account_providers).find(params[:goal_id])
    end

    def set_pledge
      @pledge = @goal.goal_pledges.find(params[:id])
    end

    def pledge_params
      params.expect(goal_pledge: %i[amount account_id])
    end

    def preselected_account
      requested = params[:account_id].presence && @goal.linked_accounts.find_by(id: params[:account_id])
      requested || @goal.linked_accounts.min_by(&:name)
    end

    def record_not_found
      redirect_to goals_path, alert: t("goals.errors.not_found")
    end
end
