# frozen_string_literal: true

json.id @message.id
json.chat_id @message.chat_id
json.type @message.type.underscore
json.role @message.role
json.content @message.content
json.model @message.ai_model if @message.type == "AssistantMessage"
json.created_at @message.created_at.iso8601
json.updated_at @message.updated_at.iso8601

# The AI response is generated asynchronously; its status is pending, streaming, complete or failed
if @message.type == "UserMessage"
  reply = @message.reply
  json.ai_response_status reply&.status || "failed"
  json.ai_response_message_id reply&.id
  json.ai_response_message reply&.in_flight? ? "AI response is being generated" : nil
end
