require "test_helper"
require Rails.root.join("script/monobank_fake/fixture_generator").to_s

class MonobankFake::FixtureGeneratorTest < ActiveSupport::TestCase
  ZONE = ActiveSupport::TimeZone["Europe/Kyiv"]
  NOW = ZONE.local(2026, 11, 15, 15, 0, 0)

  setup do
    travel_to NOW
    @family = Family.create!(name: "Generator", currency: "UAH", locale: "en", timezone: "Europe/Kyiv")
    @groceries = @family.categories.create!(name: "Groceries", classification: "expense", color: "#6172F3", lucide_icon: "tag")
    @family.categories.create!(name: "Taxi", classification: "expense", color: "#6172F3", lucide_icon: "tag")
    @account = Account.create_and_sync(
      { family: @family, name: "Mono Visa", balance: 2_000, currency: "UAH", accountable_type: "CreditCard", accountable_attributes: {} },
      skip_initial_sync: true, opening_balance_date: Date.new(2025, 8, 1)
    )
    @old = add(Date.new(2026, 11, 1), 99.99, "Old purchase")
    @overlap = [
      add(Date.new(2026, 11, 11), 45.00, "Before the window"),
      add(Date.new(2026, 11, 12), 450.00, "Silpo"),
      add(Date.new(2026, 11, 13), 320.00, "Puzata Hata"),
      add(Date.new(2026, 11, 13), 612.51, "Same amount as a template row"),
      add(Date.new(2026, 11, 14), 185.00, "Taxi")
    ]
    @account.entries.create!(date: Date.new(2026, 11, 14), amount: 9.99, currency: "UAH", name: "Generated charge",
                             source: "subscription", entryable: Transaction.new)
    @account.update!(balance: 4_321.09)
  end

  test "builds overlap rows from the hand-kept entries of the last 3 days" do
    fixture = generator.build
    rows = fixture.dig("statements", "mbf-uah-black")
    overlap = rows.select { |row| row["_manual"] }

    assert_equal Date.new(2026, 11, 15), generator.cutover
    assert_equal %w[Puzata\ Hata Same\ amount\ as\ a\ template\ row Silpo Taxi], overlap.map { |row| row["description"] }.sort
    overlap.each do |row|
      entry = Entry.find(row["_entry_id"])
      assert_equal(-(entry.amount * 100).round, row["amount"], "same signed amount, in kopecks")
      date = Time.at(row["time"]).in_time_zone(ZONE).to_date
      assert_equal row.dig("_manual", "shift_days"), (date - entry.date).to_i
      assert_includes(-1..1, row.dig("_manual", "shift_days"))
      assert_operator date, :>=, Date.new(2026, 11, 12), "inside the first fetch window (cutover - 3 days)"
      assert_operator row["time"], :<=, NOW.to_i
    end
    assert_equal 4, fixture.dig("expected", "claims")
    assert_equal({ "account_name" => "Mono Visa", "account_id" => @account.id, "monobank_account_id" => "mbf-uah-black", "cutover_date" => "auto" },
                 fixture.dig("expected", "link"))
    assert_equal "2026-11-15", fixture.dig("expected", "cutover_date")
    assert_equal 0, fixture.dig("expected", "cutover_adjustment")
  end

  test "some overlap rows are a day off, depending on the seed" do
    shifts = (1..8).map { |seed| generator(seed: seed).build.dig("statements", "mbf-uah-black").filter_map { |row| row.dig("_manual", "shift_days") } }

    assert shifts.flatten.any?(&:nonzero?), "a day's shift appears"
    assert shifts.flatten.any?(&:zero?)
    assert_equal shifts.first, generator(seed: 1).build.dig("statements", "mbf-uah-black").filter_map { |row| row.dig("_manual", "shift_days") }, "the seed repeats the fixture"
  end

  test "new rows are after the cutover, unique and never equal a hand-entered amount within 3 days" do
    fixture = generator.build
    rows = fixture.dig("statements", "mbf-uah-black")
    new_rows = rows.select { |row| row["id"].start_with?("mbf-new-", "mbf-tr-", "mbf-hold-") }
    hand = @account.entries.where(entryable_type: "Transaction").to_a

    assert_equal 14, new_rows.size
    new_rows.each do |row|
      date = Time.at(row["time"]).in_time_zone(ZONE).to_date
      assert_equal Date.new(2026, 11, 15), date, row["id"]
      assert_operator row["time"], :<=, NOW.to_i - 60
      sure_amount = BigDecimal(-row["amount"]) / 100
      clash = hand.select { |entry| entry.amount == sure_amount && (entry.date - date).abs <= 3 }
      assert_empty clash, "#{row['id']} has the amount of a hand-entered entry"
    end
    assert_equal rows.size, rows.map { |row| row["amount"] }.uniq.size + rows.count { |row| row["_manual"] } - rows.select { |row| row["_manual"] }.map { |row| row["amount"] }.uniq.size,
                 "only hand-entered rows may share amounts"
    assert_equal rows.size, rows.map { |row| row["id"] }.uniq.size
  end

  test "rows before the cutover: one never entered by hand, one older than the fetch window" do
    fixture = generator.build
    rows = fixture.dig("statements", "mbf-uah-black").index_by { |row| row["id"] }

    skipped = rows.fetch("mbf-skip-not-entered")
    assert_equal Date.new(2026, 11, 13), Time.at(skipped["time"]).in_time_zone(ZONE).to_date
    old = rows.fetch("mbf-old-before-window")
    assert_operator Time.at(old["time"]).in_time_zone(ZONE).to_date, :<, Date.new(2026, 11, 12)
    assert_equal 1, fixture.dig("expected", "skipped_before_cutover")
    assert_equal [ "mbf-old-before-window" ], fixture.dig("expected", "never_imported")
    assert_not rows.values.any? { |row| row["description"] == "Generated charge" }, "subscription charges are not hand-entered"
    assert_not rows.values.any? { |row| row["description"] == "Before the window" }
  end

  test "the card's bank balance is the hand-kept balance plus the new rows" do
    fixture = generator.build
    card = fixture["accounts"].find { |product| product["id"] == "mbf-uah-black" }
    new_rows = fixture.dig("statements", "mbf-uah-black").select { |row| row["id"].start_with?("mbf-new-", "mbf-tr-", "mbf-hold-") }
    owed = BigDecimal("4321.09") + new_rows.sum { |row| BigDecimal(-row["amount"]) / 100 }

    assert_equal owed, BigDecimal(card["creditLimit"] - card["balance"]) / 100
    assert_operator card["creditLimit"], :>=, 5_000_000
    assert_equal owed.to_f, fixture.dig("expected", "balances", "mbf-uah-black")
    assert_equal "CreditCard", fixture.dig("expected", "account_types", "mbf-uah-black")
  end

  test "a depository account gets a balance without a credit limit" do
    @account.update!(accountable: Depository.new)

    fixture = generator.build
    card = fixture["accounts"].find { |product| product["id"] == "mbf-uah-black" }
    new_rows = fixture.dig("statements", "mbf-uah-black").select { |row| row["id"].start_with?("mbf-new-", "mbf-tr-", "mbf-hold-") }

    assert_equal 0, card["creditLimit"]
    assert_equal (BigDecimal("4321.09") * 100).to_i + new_rows.sum { |row| row["amount"] }, card["balance"]
    assert_equal "Depository", fixture.dig("expected", "account_types", "mbf-uah-black")
  end

  test "transfer pairs are opposite rows at the same time; UAH -> USD at the stored rate" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "UAH", date: Date.new(2026, 11, 10), rate: 42.1)

    fixture = generator.build
    rows = fixture["statements"].values.flatten.index_by { |row| row["id"] }
    pairs = fixture.dig("expected", "transfer_pairs")

    assert_equal 4, pairs.size
    pairs.each do |pair|
      outflow, inflow = rows.fetch(pair["outflow"]), rows.fetch(pair["inflow"])
      assert_operator outflow["amount"], :<, 0
      assert_operator inflow["amount"], :>, 0
      assert_equal outflow["time"], inflow["time"]
      assert_nil outflow["_category"]
      assert_nil inflow["_category"]
    end
    usd = rows.fetch("mbf-tr-uah-to-usd")
    assert_equal 100_000, rows.fetch("mbf-tr-uah-to-usd-other")["amount"]
    assert_in_delta(-4_210_000, usd["amount"], 99 * 51)
    assert_equal 42.1, fixture.dig("expected", "exchange_rates").find { |rate| rate["from"] == "USD" }["rate"]
    assert_includes fixture.dig("statements", "mbf-fop").map { |row| row["id"] }, "mbf-tr-fop-to-card-other"
    assert_includes fixture.dig("statements", "mbf-jar-vacation").map { |row| row["id"] }, "mbf-tr-card-to-jar-other"
  end

  test "categories are expected only for the family's own category names" do
    fixture = generator.build

    assert_equal({ "groceries" => 2, "taxi" => 1 }, fixture.dig("expected", "categories"))
    assert_equal({ "groceries" => "Groceries", "taxi" => "Taxi" }, fixture.dig("expected", "category_names"))
    assert_nil fixture.dig("statements", "mbf-uah-black").find { |row| row["id"] == "mbf-new-netflix" }["_category"]
  end

  test "other products come from the sample with absolute times" do
    fixture = generator.build

    assert_equal %w[mbf-uah-black mbf-usd mbf-eur mbf-fop], fixture["accounts"].map { |product| product["id"] }
    assert_equal %w[mbf-jar-vacation mbf-jar-reserve], fixture["jars"].map { |jar| jar["id"] }
    rows = fixture["statements"].values.flatten
    assert rows.none? { |row| row.key?("days_ago") }
    assert_equal (NOW - 300.days).to_i, rows.find { |row| row["id"] == "mbf-usd-topup" }["time"]
    assert_equal [ "e2e-fake-token" ], fixture["tokens"]
  end

  test "the fixture loads into the fake and the card shows the rows of the first fetch window" do
    fixture = generator(rate_limit_seconds: 1).build
    fake = MonobankFake::App.new(fixture)
    from = ZONE.local(2026, 11, 12).to_i

    response = Rack::MockRequest.new(fake).get("/personal/statement/mbf-uah-black/#{from}", "HTTP_X_TOKEN" => "e2e-fake-token")
    ids = JSON.parse(response.body).map { |row| row["id"] }

    assert_equal 1.0, fake.rate_limit_seconds
    assert_includes ids, "mbf-skip-not-entered"
    assert_not_includes ids, "mbf-old-before-window"
    assert_equal 4 + 1 + 14, ids.size
  end

  test "with no entries at all the cutover is today" do
    @account.entries.where.not(entryable_type: "Valuation").destroy_all

    assert_equal Date.new(2026, 11, 15), generator.cutover
    assert_equal 0, generator.build.dig("expected", "claims")
  end

  test "the cutover is capped at today when the latest entry is today" do
    today = add(Date.new(2026, 11, 15), 77.77, "Today")

    fixture = generator.build

    assert_equal Date.new(2026, 11, 15), generator.cutover
    assert_includes fixture.dig("statements", "mbf-uah-black").filter_map { |row| row["_entry_id"] }, today.id
  end

  test "refuses a non-UAH account and a cutover with no time left today" do
    @account.update!(currency: "USD")
    assert_raises(ArgumentError) { generator }
    @account.update!(currency: "UAH")

    travel_to ZONE.local(2026, 11, 15, 0, 0, 30)
    error = assert_raises(ArgumentError) { generator(now: Time.current).build }
    assert_match "run later in the day", error.message
  end

  private

    def generator(seed: 1, now: NOW, rate_limit_seconds: 60)
      MonobankFake::FixtureGenerator.new(account: @account.reload, seed: seed, now: now, rate_limit_seconds: rate_limit_seconds)
    end

    def add(date, amount, name)
      @account.entries.create!(date: date, amount: amount, currency: "UAH", name: name, entryable: Transaction.new(category: @groceries))
    end
end
