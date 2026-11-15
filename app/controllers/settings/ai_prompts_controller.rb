class Settings::AiPromptsController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ t(".breadcrumb_home"), root_path ],
      [ t(".page_title"), nil ]
    ]
    @family = Current.family
    @assistant_config = { instructions: Assistant.instructions_for(Current.user) }
  end
end
