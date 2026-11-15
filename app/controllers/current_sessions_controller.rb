class CurrentSessionsController < ApplicationController
  # Answers 200 even for a key or value outside Session::ALLOWED_TABS: the tabs
  # controller fires and forgets, and an unknown pair is simply not stored.
  def update
    tab_key = session_params[:tab_key]
    tab_value = session_params[:tab_value]

    if Session.allowed_tab?(tab_key, tab_value)
      Current.session.set_preferred_tab(tab_key, tab_value)
    end

    head :ok
  end

  private
    def session_params
      params.expect(current_session: [ :tab_key, :tab_value ])
    end
end
