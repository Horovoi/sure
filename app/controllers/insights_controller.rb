# The insights feed: the full list, and dismiss with undo. The dashboard section shows
# the first Insight::FEED_LIMIT of the same list. No preview gate: the fork ships the
# feed to everyone.
class InsightsController < ApplicationController
  before_action :set_insight, only: %i[dismiss undismiss]

  def index
    @insights = visible_insights.to_a
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("insights.index.title"), nil ] ]
  end

  def dismiss
    @insight.dismiss!
    respond_with_feed
  end

  def undismiss
    @insight.undismiss!
    respond_with_feed
  end

  private
    # Any of the family's insights: undismiss targets a dismissed one
    def set_insight
      @insight = Current.family.insights.find(params[:id])
    end

    def visible_insights
      Current.family.insights.visible.ordered
    end

    # Dismiss and undo are reachable from the dashboard and from this page, so the
    # response re-renders both lists; each page applies the streams whose targets it has.
    def respond_with_feed
      @insights = visible_insights.to_a
      @feed_insights = @insights.first(Insight::FEED_LIMIT)

      respond_to do |format|
        format.turbo_stream { render action_name }
        format.html { redirect_back_or_to insights_path }
      end
    end
end
