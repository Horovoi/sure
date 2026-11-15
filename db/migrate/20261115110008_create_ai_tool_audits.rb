# One row per AI tool call, from the in-app chat (OpenAI or Claude) and from /mcp. Every tool runs with no approval
# prompt (owner answer 14), so this table is how a wrong call is found and reverted.
#
# The rows must outlive what they describe: tool_calls rows are deleted when a failed turn is retried
# (AssistantMessage#reset_attempt), Claude Code calls over /mcp have no message at all, and a chat can be deleted.
# So chat_id and assistant_message_id are plain uuids with no foreign key. Only the family (cascade) and the user
# (set null) are real references.
class CreateAiToolAudits < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_tool_audits, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }, index: true

      t.string :source, null: false
      t.string :client_name
      t.uuid :chat_id
      t.uuid :assistant_message_id

      t.string :tool_name, null: false
      t.string :scope_tag, null: false
      t.jsonb :arguments, null: false, default: {}
      t.jsonb :audit_before

      t.string :status, null: false, default: "running"
      t.string :error_message
      t.string :result_record_type
      t.string :result_record_ids, array: true, null: false, default: []
      t.integer :duration_ms
      t.datetime :finished_at

      t.timestamps
    end

    add_index :ai_tool_audits, %i[family_id created_at]
    add_index :ai_tool_audits, %i[family_id tool_name]
    add_index :ai_tool_audits, :assistant_message_id

    add_check_constraint :ai_tool_audits, "source IN ('builtin_chat', 'claude_chat', 'mcp')", name: "ai_tool_audits_source_check"
    add_check_constraint :ai_tool_audits, "status IN ('running', 'ok', 'error')", name: "ai_tool_audits_status_check"
    add_check_constraint :ai_tool_audits, "scope_tag IN ('read', 'write', 'destructive')", name: "ai_tool_audits_scope_tag_check"
  end
end
