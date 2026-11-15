class Settings::PreferencesController < ApplicationController
  layout "settings"

  def show
    @user = Current.user
    # The transfer auto-matches waiting on the review page (AutoMatchesController)
    @pending_auto_match_count = Transfer.pending.where(inflow_transaction_id: Current.family.transactions.select(:id)).count
  end
end
