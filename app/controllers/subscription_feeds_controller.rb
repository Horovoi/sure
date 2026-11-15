# The opt-in subscriptions iCal feed (decision 41). Calendar apps fetch it
# without a session, so the token in the URL is the credential: a missing,
# reset or disabled token gets a plain 404. Rack::Attack throttles the path.
class SubscriptionFeedsController < ApplicationController
  skip_authentication
  skip_before_action :require_onboarding_and_upgrade
  skip_before_action :set_default_chat
  skip_before_action :detect_os

  def show
    family = Family.find_by_subscriptions_feed_token(params[:token])
    return head(:not_found) unless family

    ics = Time.use_zone(feed_time_zone(family)) { RecurringTransaction::IcalFeed.new(family).to_ics }

    response.headers["Cache-Control"] = "private, no-store"
    send_data ics, type: "text/calendar; charset=utf-8", disposition: "inline", filename: "subscriptions.ics"
  end

  private
    # Upcoming dates are counted in the family's time zone (Kyiv), as the app does
    def feed_time_zone(family)
      ActiveSupport::TimeZone[family.timezone.to_s] || Time.zone
    end
end
