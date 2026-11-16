require "test_helper"
require "open3"
require Rails.root.join("script/monobank_fake/e2e").to_s
require Rails.root.join("script/monobank_fake/generate_fixture").to_s

# The guards and plumbing of script/monobank_fake/e2e.rb and generate_fixture.rb. The run
# itself is test/integration/monobank_end_to_end_test.rb.
class MonobankFake::ScriptsTest < ActiveSupport::TestCase
  test "e2e refuses anything but the staging copy" do
    ClimateControl.modify(DB_PORT: nil) do
      assert_refused(/only on the staging copy/) { MonobankFake::E2E.guard! }
    end
    ClimateControl.modify(DB_PORT: "5433") do
      assert_refused(/database port is "5432"/) { MonobankFake::E2E.guard! }
    end
  end

  test "e2e and the generator refuse production" do
    Rails.stubs(:env).returns("production".inquiry)

    assert_refused(/never against production/) { MonobankFake::E2E.guard! }
    assert_refused(/never against production/) { MonobankFake::GenerateFixture.guard! }
  end

  test "the generator runs in the test environment" do
    assert_nil MonobankFake::GenerateFixture.guard!
  end

  test "options after the runner's -- separator" do
    options = MonobankFake::E2E.parse([ "--", "--account", "Mono Visa", "--seed", "7", "--max-minutes", "5", "--verbose" ])
    assert_equal({ account: "Mono Visa", family_id: nil, fixture: nil, seed: 7, max_minutes: 5, verbose: true }, options)

    options = MonobankFake::GenerateFixture.parse([ "--", "--account", "Card", "--out", "tmp/x.json", "--overlap-days", "2" ])
    assert_equal({ account: "Card", family_id: nil, out: "tmp/x.json", overlap_days: 2, seed: 1 }, options)
  end

  test "e2e blocks HTTP to anything but loopback" do
    guarded = Class.new(Net::HTTP) { prepend MonobankFake::E2E::LoopbackOnly }

    error = assert_raises(Errno::ECONNREFUSED) { guarded.new("api.monobank.ua", 443).send(:connect) }
    assert_match "outbound HTTP to api.monobank.ua is blocked", error.message
  end

  test "e2e adds the fixture's rates only when none is stored, and removes what it added" do
    ExchangeRate.where(from_currency: %w[EUR UAH], to_currency: %w[EUR UAH]).delete_all
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.current - 3, rate: 41.9)
    ExchangeRate.create!(from_currency: "UAH", to_currency: "USD", date: Date.current - 3, rate: 0.0239)
    fixture = { "expected" => { "exchange_rates" => [ { "from" => "USD", "to" => "UAH", "rate" => 41.5 },
                                                       { "from" => "EUR", "to" => "UAH", "rate" => 48.2 } ] } }

    added = nil
    assert_difference -> { ExchangeRate.count }, 2 do
      capture_io { added = MonobankFake::E2E.ensure_exchange_rates(fixture, Date.current) }
    end
    assert_equal [ %w[EUR UAH], %w[UAH EUR] ], added.map { |rate| [ rate.from_currency, rate.to_currency ] }
    assert_equal 41.9, ExchangeRate.find_by(from_currency: "USD", to_currency: "UAH").rate.to_f, "a stored rate is kept"

    assert_difference -> { ExchangeRate.count }, -2 do
      capture_io { MonobankFake::E2E.remove_exchange_rates(added) }
    end
    assert ExchangeRate.exists?(from_currency: "USD", to_currency: "UAH")
  end

  test "e2e serves the fake on a free loopback port" do
    fixture = { "tokens" => [ "t" ], "accounts" => [ { "id" => "a", "balance" => 5 } ] }
    fake, server, url = MonobankFake::E2E.start_fake(fixture)

    assert_match %r{\Ahttp://127\.0\.0\.1:\d+\z}, url
    response = Net::HTTP.get_response(URI("#{url}/personal/client-info"), { "X-Token" => "t" })
    assert_equal "200", response.code
    assert_equal 5, JSON.parse(response.body)["accounts"].first["balance"]
    assert_equal 1.0, fake.rate_limit_seconds, "one request per second per function"
  ensure
    server&.stop(true)
  end

  test "e2e finds the account by name and refuses ambiguity" do
    assert_equal accounts(:credit_card), MonobankFake::E2E.find_account(name: accounts(:credit_card).name, family_id: nil)
    assert_refused(/no account named/) { MonobankFake::E2E.find_account(name: "Nope", family_id: nil) }

    other = Family.create!(name: "Other", currency: "UAH", locale: "en")
    Account.create!(family: other, name: accounts(:credit_card).name, balance: 0, currency: "USD", accountable: CreditCard.new)
    assert_refused(/2 accounts named/) { MonobankFake::E2E.find_account(name: accounts(:credit_card).name, family_id: nil) }
  end

  test "the scripts run through bin/rails runner and refuse with exit 1" do
    env = { "DB_PORT" => nil, "RAILS_ENV" => "test" }

    _out, err, status = Open3.capture3(env, "bin/rails", "runner", "script/monobank_fake/e2e.rb", "--", "--account", "Mono Visa", chdir: Rails.root.to_s)
    assert_equal 1, status.exitstatus
    assert_match "e2e: only on the staging copy", err

    _out, err, status = Open3.capture3(env, "bin/rails", "runner", "script/monobank_fake/generate_fixture.rb", "--", "--account", "No such account", chdir: Rails.root.to_s)
    assert_equal 1, status.exitstatus
    assert_match "generate_fixture: no account named", err
  end

  private

    def assert_refused(pattern, &block)
      _out, err = capture_io do
        error = assert_raises(SystemExit, &block)
        assert_equal 1, error.status
      end
      assert_match pattern, err
    end
end
