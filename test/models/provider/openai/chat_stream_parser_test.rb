require "test_helper"

class Provider::Openai::ChatStreamParserTest < ActiveSupport::TestCase
  test "parses output_text delta" do
    chunk = parse("type" => "response.output_text.delta", "delta" => "Hello")

    assert_equal "output_text", chunk.type
    assert_equal "Hello", chunk.data
  end

  test "parses refusal delta as output_text" do
    chunk = parse("type" => "response.refusal.delta", "delta" => "I cannot...")

    assert_equal "output_text", chunk.type
    assert_equal "I cannot...", chunk.data
  end

  test "returns nil for unknown event types" do
    assert_nil parse("type" => "response.created")
    assert_nil parse("type" => "response.in_progress")
  end

  test "response.failed produces an error chunk with the provider message and code" do
    chunk = parse(
      "type" => "response.failed",
      "response" => { "error" => { "message" => "Previous response not found", "code" => "previous_response_not_found" } }
    )

    assert_equal "error", chunk.type
    assert_equal "response.failed", chunk.data.event
    assert_equal "Previous response not found", chunk.data.message
    assert_equal "previous_response_not_found", chunk.data.code
  end

  test "response.incomplete produces an error chunk from incomplete_details.reason" do
    chunk = parse("type" => "response.incomplete", "response" => { "incomplete_details" => { "reason" => "max_output_tokens" } })

    assert_equal "error", chunk.type
    assert_equal "response.incomplete", chunk.data.event
    assert_equal "max_output_tokens", chunk.data.message
    assert_equal "max_output_tokens", chunk.data.code
  end

  test "response.failed without details still names the event" do
    chunk = parse("type" => "response.failed")

    assert_equal "error", chunk.type
    assert_equal "response.failed", chunk.data.event
    assert_match(/response\.failed/, chunk.data.message)
  end

  test "a top-level error event becomes an error chunk" do
    chunk = parse("type" => "error", "message" => "Rate limit exceeded", "code" => "rate_limit_exceeded")

    assert_equal "error", chunk.type
    assert_equal "error", chunk.data.event
    assert_equal "Rate limit exceeded", chunk.data.message
    assert_equal "rate_limit_exceeded", chunk.data.code
  end

  test "an error event without a message gets a generic one" do
    chunk = parse("type" => "error")

    assert_equal "OpenAI stream returned an error event", chunk.data.message
  end

  test "response.completed parses into a response chunk" do
    chunk = parse(
      "type" => "response.completed",
      "response" => { "id" => "resp_1", "model" => "gpt-4.1", "output" => [], "usage" => { "total_tokens" => 5 } }
    )

    assert_equal "response", chunk.type
    assert_equal "resp_1", chunk.data.id
    assert_equal({ "total_tokens" => 5 }, chunk.usage)
  end

  private
    def parse(object)
      Provider::Openai::ChatStreamParser.new(object).parsed
    end
end
