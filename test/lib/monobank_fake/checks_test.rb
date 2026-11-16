require "test_helper"
require Rails.root.join("script/monobank_fake/checks").to_s

# The checks of the monobank run, on a database state built by hand the way the core must
# leave it after the sample fixture (claims, skips, new entries, holds, transfer
# suggestions, balances, the jar's goal). The lookups the core and framework own (MonobankAccount,
# Entry.pending_from, Account#provider_cutover_date, FetchPlan) are stood in for.
class MonobankFake::ChecksTest < ActiveSupport::TestCase
  ZONE = ActiveSupport::TimeZone["Europe/Kyiv"]
  START = ZONE.local(2026, 11, 15, 15, 0, 0)
  CUTOVER = Date.new(2026, 11, 15)

  StandIn = Struct.new(:account_id, :current_account, :goal_id)
  StandInItem = Struct.new(:syncs) do
    def reload = self
    def backfill_progress = { chain_active: false, windows_remaining: 0, eta_seconds: 0 }
  end

  class StandInChecks < MonobankFake::Checks
    attr_accessor :stand_ins, :cutover

    def monobank_accounts = stand_ins
    def cutover_date = cutover

    def pending_entries
      Entry.joins("JOIN transactions pt ON pt.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
           .where("(pt.extra -> 'monobank' ->> 'pending')::boolean IS TRUE")
    end

    private def check_fetch_finished = record("statement fetch chain finished", true)
  end

  setup do
    travel_to START
    @fixture = MonobankFake::App.load_fixture(Rails.root.join("script/monobank_fake/fixtures/sample.json").to_s)
    @fake = MonobankFake::App.new(@fixture)
    @family = Family.create!(name: "Checks", currency: "UAH", locale: "en", timezone: "Europe/Kyiv")
    @fixture.dig("expected", "category_names").each_value do |name|
      @family.categories.create!(name: name, classification: "expense", color: "#6172F3", lucide_icon: "tag")
    end
    @mono_visa = Account.create!(family: @family, name: "Mono Visa", balance: 5_000, currency: "UAH", accountable: CreditCard.new)
    hand_kept_history
    @snapshot = MonobankFake::Checks.snapshot(@mono_visa)
    simulate_run
  end

  test "the state the core must leave passes every check" do
    checks = run_checks

    assert checks.passed?, checks.failures.map(&:to_s).join("\n")
    assert_operator checks.results.size, :>, 40
    names = checks.results.map(&:name)
    assert_includes names, "hand-entered entries claimed by bank rows: 4"
    assert_includes names, "bank rows before the cutover not imported: 1"
    assert_includes names, "transfer suggested mbf-tr-uah-to-usd -> mbf-tr-usd-in"
    assert_includes names, "every bank row has one entry (33 rows)"

    out = StringIO.new
    assert checks.report(out)
    assert_match(/^PASS  Mono Visa linked to mbf-uah-black \(cutover 2026-11-15\)$/, out.string)
    assert_match(/^PASS: all \d+ checks$/, out.string)
  end

  test "a hand-entered entry left next to a new bank entry with its amount is a duplicate" do
    cash = @mono_visa.entries.find_by!(name: "Cash at the market")
    bank_entry(@mono_visa, "mbf-extra", date: cash.date + 2, amount: cash.amount)

    assert_failed run_checks, "no manual and bank entry left as duplicates (same amount within 3 days)"
  end

  test "an external id imported twice" do
    usd = account_for("mbf-usd")
    eur = account_for("mbf-eur")
    bank_entry(eur, "mbf-usd-apple", date: CUTOVER - 120, amount: 9.99, currency: "EUR")
    assert usd

    assert_failed run_checks, "no external id imported twice", "every bank row has one entry (33 rows)"
  end

  test "a balance or a hand-entered entry changed before the cutover" do
    @mono_visa.balances.find_by!(date: CUTOVER - 5).update!(balance: 1)
    assert_failed run_checks, "balances before the cutover identical (10 days)"

    @mono_visa.balances.find_by!(date: CUTOVER - 5).update!(balance: @snapshot[:balances].find { |row| row["date"] == CUTOVER - 5 }["balance"])
    @mono_visa.entries.find_by!(name: "Silpo").update!(date: CUTOVER - 4)
    assert_failed run_checks, "hand-entered entries kept with their dates and amounts (6)"
  end

  test "current balance, account type and the cutover" do
    account_for("mbf-eur").update_columns(balance: 499)
    account_for("mbf-fop").update!(accountable: CreditCard.new)

    checks = run_checks(cutover: nil)
    assert_failed checks, "current balance mbf-eur = 500.00", "mbf-fop is a Depository", "history before the cutover unchanged",
                  "every bank row has one entry (34 rows)"
  end

  test "holds: pending count, each hold pending; after settle and cancel" do
    hold = entry_for("mbf-hold-silpo")
    hold.entryable.update!(extra: { "monobank" => { "pending" => false } })
    assert_failed run_checks, "pending holds: 2", "hold mbf-hold-silpo is one pending entry"

    entry_for("mbf-hold-uklon").destroy!
    checks = run_checks(pending: 0, pending_ids: [], gone: [ "mbf-hold-uklon" ], settled: [ "mbf-hold-silpo" ],
                        balances: @fixture.dig("expected", "balances"))
    assert checks.passed?, checks.failures.map(&:to_s).join("\n")

    hold.entryable.update!(extra: { "monobank" => { "pending" => true } })
    assert_failed run_checks(pending: 0, pending_ids: [], gone: [ "mbf-hold-uklon" ], settled: [ "mbf-hold-silpo" ]),
                  "pending holds: 0", "settled hold mbf-hold-silpo is one entry, no longer pending"
  end

  test "claims, rows skipped before the cutover and rows never fetched" do
    claimed = entry_for("mbf-ov-cafe")
    claimed.entryable.update!(extra: {})
    bank_entry(@mono_visa, "mbf-ov-kyivstar", date: CUTOVER - 2, amount: 250)
    bank_entry(@mono_visa, "mbf-old-before-window", date: CUTOVER - 10, amount: 511.30)

    assert_failed run_checks, "hand-entered entries claimed by bank rows: 4", "each claimed entry is the hand-entered one",
                  "bank row mbf-ov-cafe joined a hand-entered entry", "bank rows before the cutover not imported: 1",
                  "mbf-old-before-window (before the fetch window) not imported"
  end

  test "transfer suggestions: missing, or confirmed with kinds applied" do
    Transfer.find_by!(outflow_transaction: entry_for("mbf-tr-card-to-jar").entryable).destroy!
    transfer = Transfer.find_by!(outflow_transaction: entry_for("mbf-tr-fop-out").entryable)
    transfer.update_columns(status: "confirmed")

    assert_failed run_checks, "transfer suggested mbf-tr-card-to-jar -> mbf-tr-jar-in", "transfer suggested mbf-tr-fop-out -> mbf-tr-fop-to-card",
                  "pending transfers suggested: at least 4"
  end

  test "categories per row and per group" do
    entry_for("mbf-new-atb").entryable.update!(category: @family.categories.find_by!(name: "Taxi"))
    entry_for("mbf-tr-card-to-jar").entryable.update!(category: @family.categories.find_by!(name: "Groceries"))

    assert_failed run_checks, "category of mbf-new-atb (groceries): Groceries", "group groceries: 2 categorised",
                  "category of mbf-tr-card-to-jar (own_transfer): none"
  end

  test "requests: no early 429, gaps at least the interval" do
    get = ->(path) { Rack::MockRequest.new(@fake).get(path, "HTTP_X_TOKEN" => "e2e-fake-token") }
    get.call("/personal/client-info")
    travel 60.seconds
    get.call("/personal/client-info")
    assert run_checks.passed?

    get.call("/personal/client-info")
    assert_failed run_checks, "no request before the rate limit allowed it (3 requests)"

    assert_failed run_checks(interval: 61), "no request before the rate limit allowed it (3 requests)", "requests per token and function at least 61s apart"
  end

  test "syncs: none open past 30 minutes, none failed or stale" do
    @mono_visa.syncs.create!(status: "completed", created_at: START - 1.hour)
    assert run_checks.passed?, "completed syncs are fine"

    @mono_visa.syncs.create!(status: "syncing", created_at: START - 31.minutes)
    @mono_visa.syncs.create!(status: "failed", error: "boom")
    assert_failed run_checks, "no sync open longer than 30 minutes", "no failed or stale sync (3 syncs)"

    assert_failed run_checks(since: START - 5.minutes), "no failed or stale sync (1 syncs)"
  end

  test "jar goals: the target, a second goal, a goal for a jar without a target or for a card" do
    goal = Goal.find(@goal_ids.fetch("mbf-jar-vacation"))
    goal.update!(target_amount: 19_999)
    assert_failed run_checks, "jar mbf-jar-vacation: goal \"Відпустка\", target 20000.00"

    goal.update!(target_amount: 20_000)
    assert run_checks.passed?
    checks = run_checks(jar_goals: { "mbf-jar-vacation" => { "name" => "Відпустка в Карпатах", "target" => 20_000 } })
    assert_failed checks, "jar mbf-jar-vacation: goal \"Відпустка в Карпатах\", target 20000.00"

    reserve = @family.goals.new(name: "Reserve", target_amount: 1, currency: "UAH")
    reserve.goal_accounts.build(account: account_for("mbf-jar-reserve"))
    reserve.save!
    @goal_ids["mbf-usd"] = reserve.id
    assert_failed run_checks, "jar mbf-jar-reserve without a target has no goal", "no goal for a card or currency account"
  end

  test "a product without a linked account" do
    checks = run_checks
    checks.stand_ins = checks.stand_ins.reject { |stand_in| stand_in.account_id == "mbf-jar-reserve" }

    checks.run
    assert_includes checks.failures.map(&:name), "every product has a linked account"
  end

  private

    def run_checks(cutover: CUTOVER, interval: 60, since: nil, **options)
      checks = StandInChecks.new(family: @family, item: StandInItem.new(Sync.none), fixture: @fixture, fake: @fake,
                                 snapshot: @snapshot, account: @mono_visa, interval: interval, since: since)
      checks.stand_ins = @products.map { |fake_id, account| StandIn.new(fake_id, account, @goal_ids[fake_id]) }
      checks.cutover = cutover
      checks.run(**options) if options.any? || true
      checks
    end

    def assert_failed(checks, *names)
      failed = checks.failures.map(&:name)
      assert_equal names.sort, failed.sort, "failed checks:\n#{checks.failures.map(&:to_s).join("\n")}"
    end

    # Ten days of balances and the hand-entered entries the sample's _manual rows stand for
    def hand_kept_history
      groceries = @family.categories.find_by!(name: "Groceries")
      add = ->(date, amount, name) { @mono_visa.entries.create!(date: date, amount: amount, currency: "UAH", name: name, entryable: Transaction.new(category: groceries)) }
      add.call(CUTOVER - 9, 101.37, "Older")
      add.call(CUTOVER - 2, 77.70, "Cash at the market")
      rows("mbf-uah-black").select { |row| row["_manual"] }.each do |row|
        entry = add.call(row_date(row) + row.dig("_manual", "shift_days"), BigDecimal(-row["amount"]) / 100, row.dig("_manual", "name"))
        row["_entry_id"] = entry.id
      end
      (1..10).each do |back|
        @mono_visa.balances.create!(date: CUTOVER - back, balance: 5_000 + back, cash_balance: 5_000 + back, currency: "UAH",
                                    start_cash_balance: 5_000 + back, flows_factor: -1)
      end
    end

    # What the core must leave after the sample run
    def simulate_run
      @products = { "mbf-uah-black" => @mono_visa }
      (@fixture["accounts"] + @fixture["jars"]).each do |product|
        next if product["id"] == "mbf-uah-black"

        currency = { 980 => "UAH", 840 => "USD", 978 => "EUR" }.fetch(product["currencyCode"])
        @products[product["id"]] = Account.create!(family: @family, name: product["title"] || product["id"], balance: 0,
                                                   currency: currency, accountable: Depository.new)
      end
      never = @fixture.dig("expected", "never_imported")

      @products.each do |fake_id, account|
        rows(fake_id).each do |row|
          date = row_date(row)
          next if never.include?(row["id"])
          next if fake_id == "mbf-uah-black" && !row["_manual"] && !row["hold"] && date < CUTOVER

          if row["_manual"]
            entry = Entry.find(row["_entry_id"])
            entry.update!(external_id: "monobank_#{row['id']}", source: "monobank")
            entry.entryable.update!(extra: { "provider_claim" => { "source" => "monobank", "claimed_at" => START.iso8601 } })
          else
            category = row["_category"] && @family.categories.find_by!(name: row["_category"])
            bank_entry(account, row["id"], date: date, amount: BigDecimal(-row["amount"]) / 100, currency: account.currency,
                                           category: category, pending: row["hold"] == true)
          end
        end
      end

      @fixture.dig("expected", "transfer_pairs").each do |pair|
        Transfer.new(outflow_transaction: entry_for(pair["outflow"]).entryable, inflow_transaction: entry_for(pair["inflow"]).entryable,
                     status: "pending").save!(validate: false)
      end
      @fixture.dig("expected", "balances").each { |fake_id, amount| @products.fetch(fake_id).update_columns(balance: amount) }

      @goal_ids = {}
      @fixture.dig("expected", "jar_goals").compact.each do |fake_id, want|
        goal = @family.goals.new(name: want["name"], target_amount: want["target"], currency: "UAH")
        goal.goal_accounts.build(account: account_for(fake_id))
        goal.save!
        @goal_ids[fake_id] = goal.id
      end
    end

    def bank_entry(account, row_id, date:, amount:, currency: "UAH", category: nil, pending: false)
      account.entries.create!(date: date, amount: amount, currency: currency, name: row_id, external_id: "monobank_#{row_id}",
                              source: "monobank", entryable: Transaction.new(category: category, extra: { "monobank" => { "pending" => pending } }))
    end

    def entry_for(row_id)
      Entry.find_by!(external_id: "monobank_#{row_id}")
    end

    def account_for(fake_id)
      @products.fetch(fake_id)
    end

    def rows(fake_id)
      @fixture.dig("statements", fake_id)
    end

    def row_date(row)
      Time.at((START - Float(row["days_ago"]).days).to_i).in_time_zone(ZONE).to_date
    end
end
