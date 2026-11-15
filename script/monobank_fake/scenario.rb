# frozen_string_literal: true

require_relative "checks"
require_relative "drain"

# The monobank run both the staging script and the integration test go through, using only
# the core's public API:
#
#   1. snapshot the hand-kept account (balances and entries)
#   2. Family#create_monobank_item! and the first sync (client-info: products discovered)
#   3. MonobankItem#link_existing_account! for the expected product (Mono Visa), and
#      MonobankItem#create_linked_account! for every other product
#   4. sync and drain the queue until statement fetching is finished, then check
#   5. holds: the fake settles the first hold and cancels the second; sync, drain, check
#      that the settled one is a plain entry, the cancelled one is gone and balances moved
module MonobankFake
  class Scenario
    attr_reader :family, :account, :fixture, :fake, :drain, :item, :snapshot, :phases

    # interval: the client's MONOBANK_MIN_REQUEST_INTERVAL (seconds), for the wait between
    # phases and the interval check.
    def initialize(family:, account:, fixture:, fake:, drain:, token: nil, interval: 60, log: $stdout,
                   now: -> { Time.current })
      @family = family
      @account = account
      @fixture = fixture
      @fake = fake
      @drain = drain
      @token = token || Array(fixture["tokens"]).first
      @interval = interval.to_f
      @log = log
      @now = now
      @phases = {}
    end

    def expected
      fixture.fetch("expected", {})
    end

    # Steps 1-4. Returns the Checks (see #passed?).
    def connect_and_backfill!
      @started_at = @now.call
      @snapshot = Checks.snapshot(account)
      say "#{account.name}: #{snapshot[:entries].size} entries, #{snapshot[:balances].size} balance days, balance #{snapshot[:balance]}"

      @item = family.create_monobank_item!(access_token: @token, name: "monobank (fake)")
      say "connected #{item.class.name} #{item.id}"
      drain.run(item)

      link_products!
      item.reload.sync_later
      drain.run(item)

      record_phase(:backfill, checks.tap(&:run))
    end

    # Step 5. Returns the Checks.
    def settle_and_cancel_holds!
      holds = Array(expected["pending_ids"])
      settled, cancelled = holds[0], holds[1]
      linked_id = expected.dig("link", "monobank_account_id")
      # The holds change the balance the bank reports; the next client-info must be allowed
      drain.wait_until(@now.call + @interval + 1)
      fake.settle_hold!(account: linked_id, hold_id: settled) if settled
      fake.cancel_hold!(account: linked_id, hold_id: cancelled) if cancelled
      say "fake: settled #{settled.inspect}, cancelled #{cancelled.inspect}"

      item.reload.sync_later
      drain.run(item)

      result = checks
      result.run(pending: 0, pending_ids: [], balances: live_balances, gone: [ cancelled ].compact, settled: [ settled ].compact)
      record_phase(:holds, result)
    end

    # Step 6: the hourly sync (SyncHourlyJob) after `gap` with nothing new at the bank: no
    # statement request (no balance changed, no hold open), at most one client-info, and
    # everything still as after step 5. Returns the Checks.
    def hourly_sync_is_quiet!(gap: 1.hour)
      drain.wait_until(@now.call + [ gap, @interval + 1 ].max)
      before = fake.requests.size
      SyncHourlyJob.perform_now
      drain.run(item)
      requests = fake.requests.drop(before)

      result = checks
      result.run(pending: 0, pending_ids: [], balances: live_balances)
      statements = requests.count { |entry| entry["function"] == "statement" }
      client_info = requests.count { |entry| entry["function"] == "client_info" }
      result.add("hourly sync with nothing new asks no statement", statements.zero?, "#{statements} statement requests")
      result.add("hourly sync asks client-info once (to see balance changes)", client_info == 1, "#{client_info} client-info requests")
      record_phase(:hourly, result)
    end

    def passed?
      phases.any? && phases.values.all?(&:passed?)
    end

    def report(io = @log)
      phases.each do |name, result|
        io.puts("== #{name}")
        result.report(io)
      end
      io.puts(passed? ? "PASS" : "FAIL")
      passed?
    end

    # The balance each product must show now, from the fake's live state: a credit card
    # owes creditLimit - balance, any other account holds balance - creditLimit.
    def live_balances
      products = Array(fixture["accounts"]).map { |product| [ product, product["creditLimit"].to_i ] } +
                 Array(fixture["jars"]).map { |jar| [ jar, 0 ] }
      products.to_h do |product, limit|
        minor = fake.balance(product["id"])
        divisor = "IsoNumericCurrency".safe_constantize&.divisor(currency_code(product["currencyCode"])) || 100
        type = expected.dig("account_types", product["id"])
        amount = type == "CreditCard" ? (limit - minor) : (minor - limit)
        [ product["id"], (amount.to_d / divisor).round(2) ]
      end
    end

    private

      def checks
        Checks.new(family: family, item: item, fixture: fixture, fake: fake, snapshot: snapshot, account: account,
                   interval: @interval, since: @started_at, now: @now)
      end

      def record_phase(name, result)
        @phases[name] = result
        result
      end

      def link_products!
        mono_accounts = MonobankAccount.where(monobank_item_id: item.id).to_a
        raise "the first sync found no monobank products" if mono_accounts.empty?

        say "products: #{mono_accounts.map { |mono| "#{mono.account_id} (#{mono.suggested_account_type})" }.join(', ')}"
        linked_id = expected.dig("link", "monobank_account_id")
        target = mono_accounts.find { |mono| mono.account_id.to_s == linked_id.to_s }
        raise "no monobank product #{linked_id.inspect} to link" unless target

        cutover = expected.dig("link", "cutover_date")
        cutover = cutover.nil? || cutover == "auto" ? :auto : Date.parse(cutover)
        item.link_existing_account!(monobank_account: target, account: account, cutover_date: cutover)
        say "linked #{account.name} to #{linked_id}, cutover #{account.reload.provider_cutover_date}"

        (mono_accounts - [ target ]).each do |mono|
          created = item.create_linked_account!(monobank_account: mono)
          say "created #{created.accountable_type} #{created.name.inspect} for #{mono.account_id}"
        end
      end

      def currency_code(numeric)
        { 980 => "UAH", 840 => "USD", 978 => "EUR" }.fetch(numeric.to_i) do
          "IsoNumericCurrency".safe_constantize&.alpha_code(numeric) || raise("unknown currency #{numeric}")
        end
      end

      def say(message)
        @log&.puts(message)
      end
  end
end
