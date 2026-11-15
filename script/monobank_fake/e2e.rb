# frozen_string_literal: true

# The monobank run on the staging copy, against the fake bank, with the owner's real
# "Mono Visa" history:
#
#   BANK_CONNECTIONS_ENABLED=monobank bin/staging run bin/rails runner script/monobank_fake/e2e.rb -- \
#     [--account "Mono Visa"] [--family-id ID] [--fixture file.json] [--seed 1] [--max-minutes 30] [--verbose]
#
# It starts the fake in this process on a free 127.0.0.1 port, points the client at it
# (MONOBANK_API_BASE_URL, MONOBANK_MIN_REQUEST_INTERVAL=1; the fake allows one request per
# second per function), and runs every job itself on ActiveJob's :test adapter, waiting for
# scheduled ones in real time. Without --fixture it builds one from the account
# (FixtureGenerator). Prints PASS/FAIL per check and exits 1 on any failure.
#
# It changes the staging copy (a monobank connection, new accounts, Mono Visa linked);
# `bin/staging refresh` resets it. It refuses to run anywhere but the staging copy
# (DB_PORT=5433) and outside production. Every HTTP request to a host other than
# 127.0.0.1/localhost/::1 is refused while it runs.
require "optparse"
require "puma"
require_relative "fixture_generator"
require_relative "scenario"

module MonobankFake
  module E2E
    STAGING_DB_PORT = "5433"
    INTERVAL = 1
    LOOPBACK = %w[127.0.0.1 localhost ::1].freeze

    # Net::HTTP to loopback only: nothing in the run may reach a real bank or service
    module LoopbackOnly
      private def connect
        host = address.to_s.delete_prefix("[").delete_suffix("]")
        raise Errno::ECONNREFUSED, "monobank e2e: outbound HTTP to #{host} is blocked" unless LOOPBACK.include?(host)

        super
      end
    end

    module_function

    def refuse!(message)
      warn "e2e: #{message}"
      exit 1
    end

    def guard!
      refuse!("never against production (RAILS_ENV=production)") if Rails.env.production?
      port = ActiveRecord::Base.connection_db_config.configuration_hash[:port].to_s
      unless ENV["DB_PORT"] == STAGING_DB_PORT && port == STAGING_DB_PORT
        refuse!("only on the staging copy: run it through bin/staging run (DB_PORT=#{STAGING_DB_PORT}); database port is #{port.inspect}")
      end
    end

    def parse(argv)
      options = { account: "Mono Visa", family_id: nil, fixture: nil, seed: 1, max_minutes: 30, verbose: false }
      OptionParser.new do |parser|
        parser.banner = "Usage: bin/staging run bin/rails runner script/monobank_fake/e2e.rb -- [options]"
        parser.on("--account NAME", "hand-kept account to link (default Mono Visa)") { |value| options[:account] = value }
        parser.on("--family-id ID", "family, when several have an account with that name") { |value| options[:family_id] = value }
        parser.on("--fixture FILE", "fixture JSON (default: generated from the account)") { |value| options[:fixture] = value }
        parser.on("--seed N", Integer, "seed for the generated fixture (default 1)") { |value| options[:seed] = value }
        parser.on("--max-minutes N", Integer, "stop waiting for jobs after N minutes (default 30)") { |value| options[:max_minutes] = value }
        parser.on("--verbose", "print every job") { options[:verbose] = true }
      end.parse!(argv.reject { |arg| arg == "--" })
      options
    end

    def find_account(name:, family_id:)
      scope = Account.where(name: name)
      scope = scope.where(family_id: family_id) if family_id
      accounts = scope.to_a
      refuse!("no account named #{name.inspect}") if accounts.empty?
      refuse!("#{accounts.size} accounts named #{name.inspect}; pass --family-id") if accounts.size > 1
      account = accounts.first
      refuse!("#{account.name} is already linked to a provider; refresh the copy (bin/staging refresh)") if account.linked?
      account
    end

    # The fake on a free loopback port, served by Puma threads in this process
    def start_fake(fixture)
      app = App.new(fixture, rate_limit_seconds: INTERVAL)
      server = Puma::Server.new(app, nil, min_threads: 1, max_threads: 4)
      server.add_tcp_listener("127.0.0.1", 0)
      port = server.connected_ports.first
      server.run
      [ app, server, "http://127.0.0.1:#{port}" ]
    end

    def enable_monobank!
      return if BankConnections.enabled?(:monobank)

      ENV["BANK_CONNECTIONS_ENABLED"] = [ ENV["BANK_CONNECTIONS_ENABLED"].presence, "monobank" ].compact.join(",")
      return if BankConnections.enabled?(:monobank)

      refuse!("monobank is not enabled; run with BANK_CONNECTIONS_ENABLED=monobank")
    end

    # The rates the fixture's cross-currency transfer was priced at, when the copy has none
    # for today (the matcher needs one within 5%)
    def ensure_exchange_rates(fixture, date)
      Array(fixture.dig("expected", "exchange_rates")).each do |rate|
        [ [ rate["from"], rate["to"], rate["rate"].to_d ], [ rate["to"], rate["from"], (1 / rate["rate"].to_d).round(8) ] ].each do |from, to, value|
          next if ExchangeRate.where(from_currency: from, to_currency: to).where("date <= ? AND rate > 0", date).exists?

          ExchangeRate.create!(from_currency: from, to_currency: to, date: date, rate: value)
          puts "added exchange rate #{from}/#{to} #{value} on #{date}"
        end
      end
    end

    def run(argv)
      guard!
      options = parse(argv)
      Net::HTTP.prepend(LoopbackOnly)
      enable_monobank!
      ActiveJob::Base.queue_adapter = :test

      account = find_account(name: options[:account], family_id: options[:family_id])
      fixture =
        if options[:fixture]
          App.load_fixture(options[:fixture])
        else
          FixtureGenerator.new(account: account, seed: options[:seed], rate_limit_seconds: INTERVAL).build
        end
      fixture["expected"]["link"]["account_name"] = account.name
      ensure_exchange_rates(fixture, Date.current)

      fake, server, url = start_fake(fixture)
      ENV["MONOBANK_API_BASE_URL"] = url
      ENV["MONOBANK_MIN_REQUEST_INTERVAL"] = INTERVAL.to_s
      puts "fake monobank on #{url}, #{INTERVAL}s between requests per function; cutover expected #{fixture.dig('expected', 'cutover_date') || 'auto'}"

      log = options[:verbose] ? $stdout : nil
      drain = Drain.new(
        wait: ->(time) { sleep(0.05) while Time.current < time },
        max_duration: options[:max_minutes].minutes, raise_errors: false, log: log
      )
      scenario = Scenario.new(family: account.family, account: account, fixture: fixture, fake: fake, drain: drain,
                              interval: INTERVAL, log: $stdout)

      started = Time.current
      scenario.connect_and_backfill!
      scenario.settle_and_cancel_holds!
      scenario.hourly_sync_is_quiet!(gap: (INTERVAL + 1).seconds)

      drain.errors.each { |error| puts "job error: #{error[:job]}: #{error[:error]}" }
      puts "#{drain.performed.size} jobs, #{fake.requests.size} requests to the fake, #{(Time.current - started).round}s"
      passed = scenario.report($stdout) && drain.errors.empty?
      puts "FAIL: #{drain.errors.size} jobs raised" if drain.errors.any?
      exit(passed ? 0 : 1)
    rescue Drain::Error => e
      puts "FAIL: #{e.message}"
      scenario&.report($stdout)
      exit 1
    ensure
      server&.stop(true)
    end
  end
end

MonobankFake::E2E.run(ARGV) if $PROGRAM_NAME == __FILE__ || $PROGRAM_NAME.end_with?("e2e.rb")
