class Settings::BudgetingsController < ApplicationController
  layout "settings"

  def show
    @user = Current.user
  end
end

