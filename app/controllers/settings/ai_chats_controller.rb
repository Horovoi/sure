# The Claude part of Settings > AI. show answers the lazy frame on the AI page with the Claude card (account, plan,
# usage windows, bridge state) and the chat model select, because asking the bridge can take a few seconds the
# first time. update saves the chat model new turns use (Setting.chat_model); admins only.
class Settings::AiChatsController < ApplicationController
  before_action :require_admin, only: :update

  def show
    render partial: "settings/ai_prompts/claude_card", locals: {
      status: Assistant::Claude.status(time_zone: time_zone),
      time_zone: time_zone,
      model_options: model_options,
      current_model: Setting.chat_model.to_s
    }
  end

  def update
    model = ai_chat_params[:chat_model].to_s.strip

    if model.present? && model_options.none? { |_label, value| value == model }
      redirect_to settings_ai_prompts_path, alert: t(".invalid_model")
      return
    end

    Setting.chat_model = model.presence
    redirect_to settings_ai_prompts_path, notice: t(".saved")
  end

  private
    def ai_chat_params
      params.expect(ai_chat: [ :chat_model ])
    end

    def require_admin
      redirect_to settings_ai_prompts_path, alert: t("settings.ai_chats.not_authorized") unless Current.user.admin?
    end

    # The Claude models (from the bridge, or the aliases when it is down) and the OpenAI model when OpenAI is set up
    def model_options
      options = Assistant::Claude.model_options
      if openai_configured?
        openai = Chat.openai_model
        options += [ [ t("settings.ai_chats.openai_option", model: openai), openai ] ]
      end
      options
    end

    def openai_configured?
      ENV["OPENAI_ACCESS_TOKEN"].present? || Setting.openai_access_token.present?
    end

    def time_zone
      Current.family.timezone.presence || "Europe/Kyiv"
    end
end
