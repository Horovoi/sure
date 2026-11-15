require "test_helper"

class Provider::MonobankTest < ActiveSupport::TestCase
  BASE = "https://api.monobank.ua".freeze

  setup do
    @provider = Provider::Monobank.new("token-1")
    Provider::Monobank.any_instance.expects(:sleep).never
  end

  test "requires a token" do
    error = assert_raises(Provider::Monobank::Error) { Provider::Monobank.new("  ") }
    assert_equal :configuration_error, error.failure_code
  end

  test "sends the token in X-Token and returns client-info" do
    stub = stub_request(:get, "#{BASE}/personal/client-info")
      .with(headers: { "X-Token" => "token-1" })
      .to_return(status: 200, body: { clientId: "c1", accounts: [ { id: "a1" } ], jars: [ { id: "j1", title: "Trip" } ] }.to_json)

    info = @provider.get_client_info

    assert_requested stub, times: 1
    assert_equal "c1", info[:clientId]
    assert_equal %w[card jar], @provider.get_accounts(client_info: info).map { |a| a[:kind] }
    assert_requested stub, times: 1 # get_accounts with client_info makes no request
  end

  test "statement path uses unix seconds and tags rows with the account id" do
    from = Time.utc(2026, 11, 1)
    to = Time.utc(2026, 11, 10)
    stub_request(:get, "#{BASE}/personal/statement/acc%201/#{from.to_i}/#{to.to_i}")
      .to_return(status: 200, body: [ { id: "t1", time: from.to_i, amount: -100 } ].to_json)

    rows = @provider.get_statement(account_id: "acc 1", from: from, to: to)

    assert_equal "acc 1", rows.first[:account_id]
  end

  test "refuses a statement window over 31 days and 1 hour without a request" do
    error = assert_raises(Provider::Monobank::Error) do
      @provider.get_statement(account_id: "a", from: Time.utc(2026, 10, 1), to: Time.utc(2026, 11, 2))
    end
    assert_equal :window_too_large, error.failure_code
    assert_not_requested :get, /api.monobank.ua/
  end

  test "maps every status to a failure code" do
    { 400 => :bad_request, 401 => :unauthorized, 403 => :access_forbidden, 404 => :not_found,
      500 => :server_error, 503 => :server_error, 418 => :fetch_failed }.each do |status, code|
      ProviderRateLimitSlot.delete_all
      stub_request(:get, "#{BASE}/personal/client-info").to_return(status: status, body: { errorDescription: "nope" }.to_json)

      error = assert_raises(Provider::Monobank::Error) { @provider.get_client_info }
      assert_equal code, error.failure_code, "status #{status}"
      assert_equal code, error.as_json[:failure_code]
    end
  end

  test "a body that is not JSON is a parse error" do
    stub_request(:get, "#{BASE}/personal/client-info").to_return(status: 200, body: "<html>")

    error = assert_raises(Provider::Monobank::Error) { @provider.get_client_info }
    assert_equal :parse_error, error.failure_code
  end

  test "a statement that is not an array is a parse error" do
    stub_request(:get, %r{#{BASE}/personal/statement/}).to_return(status: 200, body: {}.to_json)

    error = assert_raises(Provider::Monobank::Error) { @provider.get_statement(account_id: "a", from: 1.day.ago, to: Time.current) }
    assert_equal :parse_error, error.failure_code
  end

  test "network errors are network_error and are not retried" do
    stub = stub_request(:get, "#{BASE}/personal/client-info").to_raise(Net::ReadTimeout)

    error = assert_raises(Provider::Monobank::Error) { @provider.get_client_info }
    assert_equal :network_error, error.failure_code
    assert_requested stub, times: 1
  end

  test "a busy slot raises RateLimitError without a request" do
    stub = stub_request(:get, "#{BASE}/personal/client-info").to_return(status: 200, body: {}.to_json)
    @provider.get_client_info

    error = assert_raises(Provider::Monobank::RateLimitError) { Provider::Monobank.new("token-1").get_client_info }

    assert_equal :rate_limited, error.failure_code
    assert_in_delta Time.current + 60, error.retry_at, 2
    assert_requested stub, times: 1
  end

  test "slots are per function and per token" do
    stub_request(:get, "#{BASE}/personal/client-info").to_return(status: 200, body: {}.to_json)
    stub_request(:get, %r{#{BASE}/personal/statement/}).to_return(status: 200, body: [].to_json)

    @provider.get_client_info
    assert_nothing_raised { @provider.get_statement(account_id: "a", from: 1.day.ago, to: Time.current) }
    assert_nothing_raised { Provider::Monobank.new("token-2").get_client_info }
  end

  test "429 defers the slot by the interval" do
    stub_request(:get, "#{BASE}/personal/client-info").to_return(status: 429, body: { errorDescription: "Too many requests" }.to_json)

    error = assert_raises(Provider::Monobank::RateLimitError) { @provider.get_client_info }

    assert_in_delta Time.current + 60, error.retry_at, 2
    assert_operator @provider.next_request_slot_at(:client_info), :>=, error.retry_at - 1
  end

  test "honours MONOBANK_MIN_REQUEST_INTERVAL" do
    with_env_overrides("MONOBANK_MIN_REQUEST_INTERVAL" => "1") do
      stub_request(:get, "#{BASE}/personal/client-info").to_return(status: 200, body: {}.to_json)
      @provider.get_client_info
      assert_in_delta Time.current + 1, @provider.next_request_slot_at(:client_info), 1
    end
  end

  test "base URL: monobank or a loopback host only" do
    [ "http://127.0.0.1:4599", "http://localhost:3000", "https://localhost", "http://[::1]:4599", "https://api.monobank.ua" ].each do |url|
      assert_nothing_raised { Provider::Monobank.new("t", base_url: url) }
    end

    [ "http://api.monobank.ua", "https://evil.example", "https://api.monobank.ua.evil.example", "http://169.254.169.254",
      "https://user@api.monobank.ua", "ftp://127.0.0.1", "not a url" ].each do |url|
      error = assert_raises(Provider::Monobank::Error, url) { Provider::Monobank.new("t", base_url: url) }
      assert_equal :invalid_url, error.failure_code
    end
  end

  test "reads MONOBANK_API_BASE_URL" do
    with_env_overrides(Provider::Monobank::BASE_URL_ENV => "http://127.0.0.1:4599") do
      stub = stub_request(:get, "http://127.0.0.1:4599/personal/client-info").to_return(status: 200, body: {}.to_json)
      Provider::Monobank.new("t").get_client_info
      assert_requested stub
    end
  end

  test "the scope key is a digest, not the token" do
    assert_not_includes @provider.rate_limit_scope_key, "token-1"
    assert_equal 32, @provider.rate_limit_scope_key.length
  end
end
