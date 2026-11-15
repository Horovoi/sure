require "test_helper"
require Rails.root.join("script/monobank_fake/scenario").to_s

# The whole monobank path against the fake bank (script/monobank_fake), with the checks the
# staging run makes (script/monobank_fake/e2e.rb): a family set up like the owner's, with a
# hand-kept "Mono Visa" credit card, connects monobank, links Mono Visa, gets new accounts
# for the other products (USD, EUR, FOP, two jars), and fetches a year of statements one
# request per minute through the continuation job. Time travels instead of sleeping; the
# fake's clock follows it.
#
# It needs the core, framework and mcc streams of the monobank port; until they are merged
# it skips.
class MonobankEndToEndTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include MonobankFakeHelper

  REQUIRED = %w[MonobankItem MonobankAccount MonobankItem::FetchPlan MonobankStatementFetchJob Account::ProviderLink
                Mcc::CategoryMatcher BankConnections].freeze
  INTERVAL = 60
  # 15:00 in Kyiv: the sample fixture's days_ago < 0.625 fall on "today"
  START = ActiveSupport::TimeZone["Europe/Kyiv"].local(2026, 11, 15, 15, 0, 0)

  setup do
    missing = REQUIRED.reject { |name| name.safe_constantize }
    skip "needs the monobank port (missing #{missing.join(', ')})" if missing.any?
    skip "needs Entry.pending_from" unless Entry.respond_to?(:pending_from)

    travel_to START
    enable_bank_connections(:monobank)

    @fixture = monobank_sample_fixture
    @family = Family.create!(name: "Monobank E2E", currency: "UAH", locale: "en", timezone: "Europe/Kyiv")
    create_categories
    create_exchange_rates
    @mono_visa = create_mono_visa
  end

  test "connect, link Mono Visa, backfill every product, settle holds, quiet hourly sync" do
    with_monobank_fake(@fixture, min_request_interval: INTERVAL) do |fake|
      scenario = MonobankFake::Scenario.new(family: @family, account: @mono_visa, fixture: @fixture, fake: fake,
                                            drain: drain, interval: INTERVAL, log: verbose_log)

      assert_checks scenario.connect_and_backfill!
      assert_equal START.to_date, @mono_visa.reload.provider_cutover_date, "cutover: the day after the latest hand-entered entry"
      assert_operator fake.requests.count { |entry| entry["function"] == "statement" && entry["status"] == 500 }, :>=, 1,
                      "the EUR fault was served (and the account recovered)"

      assert_checks scenario.settle_and_cancel_holds!
      assert_checks scenario.hourly_sync_is_quiet!

      scenario.report if verbose_log
    end
  end

  test "a statement import into the linked account is refused" do
    with_monobank_fake(@fixture, min_request_interval: INTERVAL) do |fake|
      scenario = MonobankFake::Scenario.new(family: @family, account: @mono_visa, fixture: @fixture, fake: fake,
                                            drain: drain, interval: INTERVAL, log: verbose_log)
      scenario.connect_and_backfill!

      import = @family.imports.new(type: "TransactionImport", account: @mono_visa)
      assert_not import.valid?
      assert_includes import.errors.details[:account].map { |detail| detail[:error] }, :provider_linked
    end
  end

  private

    def drain
      MonobankFake::Drain.new(adapter: queue_adapter, wait: ->(time) { travel_to(Time.at(time.to_r.ceil)) }, log: verbose_log)
    end

    def verbose_log
      $stdout if ENV["MONOBANK_E2E_VERBOSE"].present?
    end

    def assert_checks(checks)
      assert checks.results.any?, "no checks ran"
      failures = checks.failures
      assert failures.empty?, "#{failures.size} of #{checks.results.size} checks failed:\n#{failures.map(&:to_s).join("\n")}"
    end

    # The owner's category names (expense and income)
    def create_categories
      %w[Groceries Eating\ Out Coffee\ Out Food\ &\ Drinks Taxi Public\ Transport Pharmacies Health Streaming
         Subscription\ Services Mobile\ Plan Fees Shopping Utilities Travel P2P\ Outgoing].each do |name|
        @family.categories.create!(name: name, classification: "expense", color: "#6172F3", lucide_icon: "tag")
      end
      %w[Salary Interest Refund P2P\ Incoming].each do |name|
        @family.categories.create!(name: name, classification: "income", color: "#10A861", lucide_icon: "tag")
      end
    end

    def create_exchange_rates
      rows = ((START.to_date - 400.days)..START.to_date).step(7).to_a.push(START.to_date).flat_map do |date|
        @fixture.dig("expected", "exchange_rates").flat_map do |rate|
          [ { from_currency: rate["from"], to_currency: rate["to"], date: date, rate: rate["rate"] },
            { from_currency: rate["to"], to_currency: rate["from"], date: date, rate: (1.0 / rate["rate"]).round(8) } ]
        end
      end
      ExchangeRate.upsert_all(rows, unique_by: %i[from_currency to_currency date])
    end

    # A UAH credit card kept by hand since 2025-08-01 (as the owner's), whose last entries
    # are the sample's _manual rows (some a day off, as hand-entered ones are).
    def create_mono_visa
      account = Account.create_and_sync(
        { family: @family, name: "Mono Visa", balance: 3_000, currency: "UAH", accountable_type: "CreditCard",
          accountable_attributes: {} },
        skip_initial_sync: true, opening_balance_date: Date.new(2025, 8, 1)
      )
      groceries = @family.categories.find_by!(name: "Groceries")

      # Older history: a purchase every 9 days with amounts no bank row has
      date = Date.new(2025, 8, 3)
      index = 0
      while date < START.to_date - 4
        add_manual(account, date: date, amount: 100 + index * 1.37, name: "Hand-entered #{index}", category: groceries)
        date += 9
        index += 1
      end
      add_manual(account, date: START.to_date - 2, amount: 77.70, name: "Cash at the market")

      fake_rows(account) do |row, date|
        entry = add_manual(account, date: date + row.dig("_manual", "shift_days").to_i, amount: -row["amount"] / 100.0, name: row.dig("_manual", "name"))
        row["_entry_id"] = entry.id
      end

      account.sync_later
      drain.run
      account.reload
    end

    def add_manual(account, date:, amount:, name:, category: nil)
      account.entries.create!(date: date, amount: amount.to_d.round(2), currency: "UAH", name: name,
                              entryable: Transaction.new(category: category))
    end

    def fake_rows(_account)
      linked = @fixture.dig("expected", "link", "monobank_account_id")
      @fixture["statements"][linked].select { |row| row["_manual"] }.each do |row|
        time = START - Float(row["days_ago"]).days
        yield row, time.in_time_zone("Europe/Kyiv").to_date
      end
    end
end
