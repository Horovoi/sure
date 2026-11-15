require Rails.root.join("script/monobank_fake/app").to_s

# Points the monobank client at the fake bank (script/monobank_fake/app.rb) for the length
# of a block. No socket is opened: WebMock hands every request to http://127.0.0.1:4599 to
# the Rack app, so the client's real HTTP code runs against the bank's real wire format.
#
#   include MonobankFakeHelper
#
#   with_monobank_fake(monobank_sample_fixture) do |fake|
#     family.create_monobank_item!(access_token: "e2e-fake-token")
#     ...
#     assert_equal 0, fake.early_requests
#   end
#
# The fake's clock is Time.now, so travel_to moves it too (rate limits, days_ago).
module MonobankFakeHelper
  MONOBANK_FAKE_URL = "http://127.0.0.1:4599".freeze
  SAMPLE_FIXTURE = Rails.root.join("script/monobank_fake/fixtures/sample.json").freeze

  # fixture: a Hash (see script/monobank_fake/README.md); the sample when nil.
  # min_request_interval: sets MONOBANK_MIN_REQUEST_INTERVAL for the client, and by default
  #   the fake's rate limit to the same number of seconds.
  # rate_limit_seconds: the fake's limit when it should differ from the client's interval.
  # env: more ENV overrides for the block (e.g. "MONOBANK_INITIAL_HISTORY_DAYS" => "30").
  def with_monobank_fake(fixture = nil, min_request_interval: nil, rate_limit_seconds: nil, env: {})
    fixture ||= monobank_sample_fixture
    rate_limit_seconds ||= min_request_interval
    fake = MonobankFake::App.new(fixture, rate_limit_seconds: rate_limit_seconds)

    overrides = { monobank_base_url_env => MONOBANK_FAKE_URL }
    overrides["MONOBANK_MIN_REQUEST_INTERVAL"] = min_request_interval.to_s if min_request_interval
    overrides.merge!(env.transform_keys(&:to_s).transform_values { |value| value&.to_s })

    stub = stub_request(:any, /\A#{Regexp.escape(MONOBANK_FAKE_URL)}\//)
    stub.to_rack(fake)
    begin
      ClimateControl.modify(**overrides.transform_keys(&:to_sym)) { yield fake }
    ensure
      remove_request_stub(stub)
    end
  end

  # A fresh copy of script/monobank_fake/fixtures/sample.json, free to change in a test
  def monobank_sample_fixture
    MonobankFake::App.load_fixture(SAMPLE_FIXTURE.to_s)
  end

  private

    def monobank_base_url_env
      "Provider::Monobank".safe_constantize&.const_get(:BASE_URL_ENV, false) || "MONOBANK_API_BASE_URL"
    rescue NameError
      "MONOBANK_API_BASE_URL"
    end
end
