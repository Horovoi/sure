require "test_helper"

class AiToolAuditTest < ActiveSupport::TestCase
  test "storable redacts filtered keys at any depth" do
    stored = AiToolAudit.storable({ "query" => "rent", "auth" => { "password" => "hunter2", "otp_code" => "123456" } })

    assert_equal "rent", stored["query"]
    assert_equal "[FILTERED]", stored.dig("auth", "password")
    assert_equal "[FILTERED]", stored.dig("auth", "otp_code")
  end

  test "storable turns symbols, dates and decimals into plain JSON values" do
    stored = AiToolAudit.storable({ id: "a1", date: Date.new(2026, 11, 15), amount: BigDecimal("12.50") })

    assert_equal({ "id" => "a1", "date" => "2026-11-15", "amount" => "12.5" }, stored)
  end

  test "storable caps large values and marks them truncated" do
    stored = AiToolAudit.storable({ "notes" => "\"quoted\" " * 10_000 })

    assert_equal true, stored["_truncated"]
    assert stored["_bytes"] > AiToolAudit::MAX_JSON_BYTES
    assert stored.to_json.bytesize <= AiToolAudit::MAX_JSON_BYTES
  end

  test "storable wraps a value that is not an object" do
    assert_equal({ "_raw" => "{not json" }, AiToolAudit.storable("{not json"))
    assert_nil AiToolAudit.storable(nil)
  end

  test "a running row older than an hour shows as interrupted" do
    audit = ai_tool_audits(:write_call)
    audit.status = "running"

    audit.created_at = 2.hours.ago
    assert_equal "interrupted", audit.display_status

    audit.created_at = 1.minute.ago
    assert_equal "running", audit.display_status
  end

  test "source, status and scope tag are checked" do
    audit = ai_tool_audits(:read_call)

    audit.source = "openclaw"
    assert_not audit.valid?

    audit.source = "mcp"
    audit.status = "maybe"
    assert_not audit.valid?

    audit.status = "ok"
    audit.scope_tag = "admin"
    assert_not audit.valid?
  end

  test "writes leaves out reads" do
    assert_includes AiToolAudit.writes, ai_tool_audits(:write_call)
    assert_not_includes AiToolAudit.writes, ai_tool_audits(:read_call)
  end

  test "deleting the user keeps the row without a user" do
    member = users(:family_member)
    audit = AiToolAudit.create!(family: member.family, user: member, source: "builtin_chat", tool_name: "get_accounts",
      scope_tag: "read", status: "ok")

    member.destroy!

    assert_nil audit.reload.user_id
  end
end
