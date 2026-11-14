# frozen_string_literal: true

class Api::V1::MessagesController < Api::V1::BaseController
  before_action :require_ai_enabled
  before_action :ensure_write_scope, only: [ :create, :retry ]
  before_action :set_chat

  def create
    @message = @chat.ask!(message_params[:content], ai_model: message_params[:model]).prompt
    render :show, status: :created
  rescue Chat::TurnInProgressError
    render json: { error: "response_in_progress", message: "Wait for the current response to finish" }, status: :conflict
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Failed to create message", details: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  # Retries the last turn when it failed, was lost, or never got a response
  def retry
    turn = @chat.retry_last_turn!
    render json: { message: "Retry initiated", message_id: turn.id }, status: :accepted
  rescue Chat::TurnInProgressError
    render json: { error: "response_in_progress", message: "Wait for the current response to finish" }, status: :conflict
  rescue Chat::NothingToRetryError
    render json: { error: "Nothing to retry" }, status: :unprocessable_entity
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def set_chat
      @chat = Current.user.chats.find(params[:chat_id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Chat not found" }, status: :not_found
    end

    def message_params
      params.permit(:content, :model)
    end
end
