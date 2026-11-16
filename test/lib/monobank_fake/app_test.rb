require "test_helper"
require Rails.root.join("script/monobank_fake/app").to_s

class MonobankFake::AppTest < ActiveSupport::TestCase
  TOKEN = "test-token".freeze
  START = Time.utc(2026, 11, 15, 13, 0, 0)

  setup do
    @now = START
    @fixture = {
      "tokens" => [ TOKEN, "second-token" ],
      "rate_limit_seconds" => 60,
      "client" => { "clientId" => "c1", "name" => "Тест" },
      "accounts" => [
        { "id" => "uah", "currencyCode" => 980, "balance" => 100_000, "creditLimit" => 50_000, "type" => "black",
          "maskedPan" => [ "537541******1234" ], "iban" => "UA001" },
        { "id" => "usd", "currencyCode" => 840, "balance" => 5_000 }
      ],
      "jars" => [ { "id" => "jar", "title" => "Відпустка", "balance" => 7_000, "goal" => 100_000, "_note" => "x" } ],
      "statements" => {
        "uah" => [
          { "id" => "old", "days_ago" => 40, "amount" => -1_000, "description" => "Старе" },
          { "id" => "a", "days_ago" => 2, "amount" => -2_000, "mcc" => 5411, "description" => "Сільпо", "_group" => "groceries" },
          { "id" => "b", "days_ago" => 1, "amount" => 10_000, "comment" => "Повернення боргу" },
          { "id" => "hold", "days_ago" => 0.1, "amount" => -500, "hold" => true }
        ],
        "jar" => [ { "id" => "j1", "time" => START.to_i - 3600, "amount" => 7_000, "balance" => 7_000 } ]
      }
    }
  end

  test "client-info returns the client, its cards and jars in the bank's wire format" do
    response = get("/personal/client-info")

    assert_equal 200, response.status
    assert_match %r{application/json}, response.headers["content-type"]
    body = JSON.parse(response.body)
    assert_equal "c1", body["clientId"]
    assert_equal "Тест", body["name"]
    assert_equal "psfj", body["permissions"]
    assert_equal "", body["webHookUrl"]

    uah = body["accounts"].find { |account| account["id"] == "uah" }
    assert_equal({ "id" => "uah", "sendId" => "", "currencyCode" => 980, "cashbackType" => "UAH", "balance" => 100_000,
                   "creditLimit" => 50_000, "maskedPan" => [ "537541******1234" ], "type" => "black", "iban" => "UA001" }, uah)
    assert_equal 840, body["accounts"].find { |account| account["id"] == "usd" }["currencyCode"]

    jar = body["jars"].sole
    assert_equal({ "id" => "jar", "sendId" => "", "title" => "Відпустка", "description" => "", "currencyCode" => 980,
                   "balance" => 7_000, "goal" => 100_000 }, jar)
  end

  test "statement returns the window's rows newest first with every field and computed balances" do
    rows = JSON.parse(get(statement_path("uah", START - 31.days, START)).body)

    assert_equal %w[hold b a], rows.map { |row| row["id"] }
    hold, refund, silpo = rows
    assert_equal true, hold["hold"]
    assert_equal 100_000, hold["balance"], "the newest row carries the account balance"
    assert_equal 100_500, refund["balance"], "each older row: the newer balance minus the newer amount"
    assert_equal 90_500, silpo["balance"]

    assert_equal (START - 2.days).to_i, silpo["time"]
    assert_equal({ "id" => "a", "time" => (START - 2.days).to_i, "description" => "Сільпо", "mcc" => 5411, "originalMcc" => 5411,
                   "hold" => false, "amount" => -2_000, "operationAmount" => -2_000, "currencyCode" => 980,
                   "commissionRate" => 0, "cashbackAmount" => 0, "balance" => 90_500 }, silpo)
    assert_equal "Повернення боргу", refund["comment"]
    assert_not silpo.key?("comment"), "optional fields are left out when empty, as the bank does"
    assert_not silpo.key?("_group"), "fixture notes are never sent"
  end

  test "an explicit row balance is kept and older balances count from it" do
    rows = JSON.parse(get(statement_path("jar", START - 1.day, START)).body)

    assert_equal [ 7_000 ], rows.map { |row| row["balance"] }
  end

  test "to defaults to now and account 0 is the first card" do
    rows = JSON.parse(get("/personal/statement/0/#{(START - 3.days).to_i}").body)

    assert_equal %w[hold b a], rows.map { |row| row["id"] }
    assert_nil app.requests.last["to"]
  end

  test "a window longer than 31 days and 1 hour is refused with 400" do
    response = get(statement_path("uah", START - 2_682_001.seconds, START))

    assert_equal 400, response.status
    assert_equal "Period must be no more than 31 days", JSON.parse(response.body)["errorDescription"]

    @now += 61
    assert_equal 200, get(statement_path("uah", START - 2_682_000.seconds, START)).status, "exactly 31 days + 1 hour is allowed"
  end

  test "a window that ends before it starts and an unknown account are refused with 400" do
    assert_equal 400, get(statement_path("uah", START, START - 1.day)).status
    @now += 61
    response = get(statement_path("nope", START - 1.day, START))
    assert_equal 400, response.status
    assert_equal "Invalid account", JSON.parse(response.body)["errorDescription"]
  end

  test "statement returns at most 500 rows, the newest ones" do
    items = (1..520).map { |i| { "id" => "r#{i}", "time" => START.to_i - i * 60, "amount" => -100 } }
    @fixture["statements"] = { "usd" => items }

    rows = JSON.parse(get(statement_path("usd", START - 1.day, START)).body)

    assert_equal 500, rows.size
    assert_equal "r1", rows.first["id"]
    assert_equal "r500", rows.last["id"]
    assert_equal 500, app.requests.last["rows"]

    @now += 61
    rest = JSON.parse(get(statement_path("usd", START - 1.day, Time.at(rows.last["time"]))).body)
    assert_equal (500..520).map { |i| "r#{i}" }, rest.map { |row| row["id"] }, "paging by moving `to` to the oldest row (inclusive)"
  end

  test "an unknown token gets 403 and a missing one 401" do
    response = get("/personal/client-info", token: "wrong")
    assert_equal 403, response.status
    assert_equal "Unknown 'X-Token'", JSON.parse(response.body)["errorDescription"]

    assert_equal 401, get("/personal/client-info", token: nil).status
    assert_nil app.requests.last["token"]
  end

  test "rate limit: one request per interval per token and per function, 429 with the bank's body" do
    assert_equal 200, get("/personal/client-info").status

    @now += 59.9
    early = get("/personal/client-info")
    assert_equal 429, early.status
    assert_equal({ "errorDescription" => "Too many requests" }, JSON.parse(early.body))

    assert_equal 200, get(statement_path("uah", START - 1.day, START)).status, "statement has its own timer"
    assert_equal 200, get("/personal/client-info", token: "second-token").status, "each token has its own timer"

    @now = START + 60
    assert_equal 200, get("/personal/client-info").status, "a rejected request does not restart the timer"

    log = app.requests
    assert_equal [ 200, 429, 200, 200, 200 ], log.map { |entry| entry["status"] }
    assert_equal [ false, true, false, false, false ], log.map { |entry| entry["early"] == true }
    assert_equal 1, app.early_requests
    assert_in_delta 59.9, log[1]["since_previous"], 0.001
    assert_in_delta 60.0, log[4]["since_previous"], 0.001
  end

  test "rate_limit_seconds comes from the keyword, then the environment, then the fixture" do
    assert_equal 60.0, app.rate_limit_seconds

    ClimateControl.modify(MonobankFake::App::RATE_LIMIT_ENV => "2") do
      assert_equal 2.0, MonobankFake::App.new(@fixture).rate_limit_seconds
      assert_equal 0.5, MonobankFake::App.new(@fixture, rate_limit_seconds: 0.5).rate_limit_seconds
    end

    @fixture.delete("rate_limit_seconds")
    assert_equal 60.0, MonobankFake::App.new(@fixture).rate_limit_seconds

    unlimited = MonobankFake::App.new(@fixture, clock: -> { @now }, rate_limit_seconds: 0)
    2.times { assert_equal 200, Rack::MockRequest.new(unlimited).get("/personal/client-info", "HTTP_X_TOKEN" => TOKEN).status }
  end

  test "faults answer with their status a given number of times, then the real response" do
    @fixture["faults"] = [
      { "path_prefix" => "/personal/statement/usd", "status" => 500, "times" => 1 },
      { "path_prefix" => "/personal/client-info", "status" => 429, "times" => 1, "body" => { "errorDescription" => "Too many requests" } }
    ]

    failed = get(statement_path("usd", START - 1.day, START))
    assert_equal 500, failed.status
    assert_equal "Fake fault", JSON.parse(failed.body)["errorDescription"]
    @now += 60
    assert_equal 200, get(statement_path("usd", START - 1.day, START)).status

    assert_equal 429, get("/personal/client-info").status
    assert_equal [ true, nil, true ], app.requests.map { |entry| entry["fault"] }
    assert_equal 0, app.early_requests, "a fault 429 is not an early request"
  end

  test "a fault can raise a connection error instead of answering" do
    @fixture["faults"] = [ { "path_prefix" => "/personal/client-info", "raise" => "Errno::ECONNRESET" } ]

    assert_raises(Errno::ECONNRESET) { get("/personal/client-info") }
  end

  test "settle_hold turns a hold into a settled row and moves the balance by the difference" do
    post_admin("/__fake/settle_hold", account: "uah", hold_id: "hold", amount: -700)

    rows = JSON.parse(get(statement_path("uah", START - 1.day, START)).body)
    settled = rows.find { |row| row["id"] == "hold" }
    assert_equal false, settled["hold"]
    assert_equal(-700, settled["amount"])
    assert_equal 99_800, app.balance("uah")
    assert_equal 99_800, settled["balance"]
  end

  test "settle_hold with a settled_id replaces the hold by a new row" do
    app.settle_hold!(account: "uah", hold_id: "hold", settled_id: "settled-1")

    ids = app.statement("uah").map { |row| row["id"] }
    assert_includes ids, "settled-1"
    assert_not_includes ids, "hold"
    assert_equal 100_000, app.balance("uah")
  end

  test "cancel_hold removes the hold and returns its amount" do
    post_admin("/__fake/cancel_hold", account: "uah", hold_id: "hold")

    assert_not_includes app.statement("uah").map { |row| row["id"] }, "hold"
    assert_equal 100_500, app.balance("uah")
    assert_equal 100_500, JSON.parse(get("/personal/client-info").body)["accounts"].first["balance"]
  end

  test "settle_hold and cancel_hold refuse a row that is not a hold" do
    response = post_admin("/__fake/settle_hold", account: "uah", hold_id: "a")
    assert_equal 400, response.status
    assert_equal 404, post_admin("/__fake/cancel_hold", account: "uah", hold_id: "missing").status
    assert_equal 404, post_admin("/__fake/add", account: "missing", item: { amount: 1 }).status
    assert_equal 400, post_admin("/__fake/add", account: "uah").status
  end

  test "add puts a new row dated now and moves the balance" do
    @now += 120
    response = post_admin("/__fake/add", account: "usd", item: { id: "new", amount: -1_234, mcc: 5812, description: "Кафе" })

    assert_equal 200, response.status
    row = app.statement("usd").first
    assert_equal "new", row["id"]
    assert_equal (START + 120).to_i, row["time"]
    assert_equal 3_766, row["balance"]
    assert_equal 3_766, app.balance("usd")

    post_admin("/__fake/add", account: "usd", item: { amount: 1, days_ago: 1 })
    assert_equal (START + 120 - 1.day).to_i, app.statement("usd").last["time"], "days_ago counts from now"
  end

  test "update_jar renames a jar and moves or removes its target" do
    response = post_admin("/__fake/update_jar", jar: "jar", title: "Відпустка в Карпатах", goal: 150_000)

    assert_equal 200, response.status
    jar = JSON.parse(get("/personal/client-info").body)["jars"].sole
    assert_equal [ "Відпустка в Карпатах", 150_000, 7_000 ], jar.values_at("title", "goal", "balance")

    app.update_jar!(jar: "jar", goal: nil)
    assert_equal [ "Відпустка в Карпатах", nil ], JSON.parse(admin_get("/__fake/state").body)["jars"].sole.values_at("title", "goal"),
                 "only the keys given change"

    assert_equal 404, post_admin("/__fake/update_jar", jar: "uah", title: "x").status, "cards are not jars"
    assert_equal 400, post_admin("/__fake/update_jar", jar: "jar", balance: 1).status
    assert_equal 400, post_admin("/__fake/update_jar", title: "x").status

    post_admin("/__fake/reset")
    assert_equal [ "Відпустка", 100_000 ], JSON.parse(admin_get("/__fake/state").body)["jars"].sole.values_at("title", "goal")
  end

  test "reset goes back to the fixture and clears the log and the rate limits" do
    get("/personal/client-info")
    app.cancel_hold!(account: "uah", hold_id: "hold")
    @now += 5

    post_admin("/__fake/reset")

    assert_equal 100_000, app.balance("uah")
    assert_includes app.statement("uah").map { |row| row["id"] }, "hold"
    assert_equal (START + 5 - 2.days).to_i, app.statement("uah").find { |row| row["id"] == "a" }["time"], "days_ago re-anchored"
    assert_equal 200, get("/personal/client-info").status, "rate limit cleared"
    assert_equal 1, app.requests.size
  end

  test "log and state are reachable over HTTP" do
    get("/personal/client-info")
    get("/personal/client-info")

    log = JSON.parse(admin_get("/__fake/log").body)
    assert_equal [ 200, 429 ], log["requests"].map { |entry| entry["status"] }
    assert_equal 1, log["early_429"]
    assert_equal START.to_f, log["requests"].first["at"]

    state = JSON.parse(admin_get("/__fake/state").body)
    assert_equal({ "uah" => 4, "jar" => 1 }, state["rows"])
    assert_equal 60.0, state["rate_limit_seconds"]
    assert_equal %w[uah usd], state["accounts"].map { |account| account["id"] }
  end

  test "admin endpoints are hidden without the admin header and admin calls are not logged" do
    assert_equal 404, Rack::MockRequest.new(app).post("/__fake/reset").status
    assert_equal 404, Rack::MockRequest.new(app).get("/__fake/log", "HTTP_X_TOKEN" => TOKEN).status
    assert_equal 404, admin_get("/__fake/nothing").status
    assert_empty app.requests
  end

  test "unknown paths and methods" do
    assert_equal 404, get("/personal/other").status
    assert_equal 405, Rack::MockRequest.new(app).post("/personal/client-info", "HTTP_X_TOKEN" => TOKEN).status
  end

  test "a statement item needs time or days_ago" do
    @fixture["statements"] = { "usd" => [ { "id" => "x", "amount" => 1 } ] }

    error = assert_raises(ArgumentError) { app }
    assert_match "neither time nor days_ago", error.message
  end

  test "the sample fixture loads and its expected block is consistent with its rows" do
    sample = MonobankFake::App.load_fixture(Rails.root.join("script/monobank_fake/fixtures/sample.json").to_s)
    fake = MonobankFake::App.new(sample, clock: -> { @now })
    expected = sample["expected"]
    rows = sample["statements"].values.flatten

    assert_equal expected["claims"], rows.count { |row| row["_manual"] }
    assert_equal expected["pending"], rows.count { |row| row["hold"] }
    assert_equal expected["pending_ids"].sort, rows.select { |row| row["hold"] }.map { |row| row["id"] }.sort
    assert_equal expected["transfers"], expected["transfer_pairs"].size
    expected["transfer_pairs"].each do |pair|
      assert rows.any? { |row| row["id"] == pair["outflow"] && row["amount"].negative? }, pair.inspect
      assert rows.any? { |row| row["id"] == pair["inflow"] && row["amount"].positive? }, pair.inspect
    end
    expected["categories"].each do |group, count|
      next if group == "own_transfer"

      assert_equal count, rows.count { |row| row["_group"] == group && row["_category"] == expected["category_names"][group] }, group
    end
    assert_equal rows.size, rows.map { |row| row["id"] }.uniq.size, "row ids are unique"

    card = sample["accounts"].find { |account| account["id"] == expected["link"]["monobank_account_id"] }
    assert_equal expected["balances"][card["id"]], (card["creditLimit"] - card["balance"]) / 100.0
    (sample["accounts"] + sample["jars"]).each do |product|
      assert_equal product["balance"], fake.balance(product["id"])
    end
  end

  private

    def app
      @app ||= MonobankFake::App.new(@fixture, clock: -> { @now })
    end

    def get(path, token: TOKEN)
      headers = token ? { "HTTP_X_TOKEN" => token } : {}
      Rack::MockRequest.new(app).get(path, headers)
    end

    def admin_get(path)
      Rack::MockRequest.new(app).get(path, "HTTP_X_FAKE_ADMIN" => "1")
    end

    def post_admin(path, body = {})
      Rack::MockRequest.new(app).post(path, "HTTP_X_FAKE_ADMIN" => "1", "CONTENT_TYPE" => "application/json", input: JSON.generate(body))
    end

    def statement_path(account, from, to)
      "/personal/statement/#{account}/#{from.to_i}/#{to.to_i}"
    end
end

class MonobankFakeHelperTest < ActiveSupport::TestCase
  include MonobankFakeHelper

  test "with_monobank_fake serves the fake on 127.0.0.1:4599 through WebMock and sets the client's ENV" do
    with_monobank_fake(min_request_interval: 1, env: { "MONOBANK_INITIAL_HISTORY_DAYS" => 30 }) do |fake|
      assert_equal MonobankFakeHelper::MONOBANK_FAKE_URL, ENV["MONOBANK_API_BASE_URL"]
      assert_equal "1", ENV["MONOBANK_MIN_REQUEST_INTERVAL"]
      assert_equal "30", ENV["MONOBANK_INITIAL_HISTORY_DAYS"]
      assert_equal 1.0, fake.rate_limit_seconds

      response = HTTParty.get("#{ENV['MONOBANK_API_BASE_URL']}/personal/client-info", headers: { "X-Token" => "e2e-fake-token" })
      assert_equal 200, response.code
      assert_equal "fakeClient01", JSON.parse(response.body)["clientId"]
      assert_equal 429, HTTParty.get("#{MonobankFakeHelper::MONOBANK_FAKE_URL}/personal/client-info", headers: { "X-Token" => "e2e-fake-token" }).code
      assert_equal 403, HTTParty.get("#{MonobankFakeHelper::MONOBANK_FAKE_URL}/personal/client-info", headers: { "X-Token" => "other" }).code
      assert_equal 1, fake.early_requests
    end

    assert_nil ENV["MONOBANK_API_BASE_URL"]
    signature = WebMock::RequestSignature.new(:get, "#{MonobankFakeHelper::MONOBANK_FAKE_URL}/personal/client-info")
    assert_nil WebMock::StubRegistry.instance.registered_request?(signature), "the stub is removed after the block"
  end

  test "the fake's clock follows travel_to" do
    travel_to Time.zone.parse("2026-11-15 15:00:00 +0200") do
      fixture = monobank_sample_fixture.merge("faults" => []) # the sample's first statement is a 429
      with_monobank_fake(fixture) do |fake|
        assert_equal Time.current.to_i, fake.started_at.to_i
        assert_equal 60.0, fake.rate_limit_seconds, "the fixture's limit when no interval is given"

        from = (Time.current - 1.day).to_i
        url = "#{MonobankFakeHelper::MONOBANK_FAKE_URL}/personal/statement/mbf-uah-black/#{from}"
        rows = JSON.parse(HTTParty.get(url, headers: { "X-Token" => "e2e-fake-token" }).body)
        assert_equal "mbf-hold-uklon", rows.first["id"]
        assert_equal (Time.current - 0.04.days).to_i, rows.first["time"]

        travel 59.seconds
        assert_equal 429, HTTParty.get(url, headers: { "X-Token" => "e2e-fake-token" }).code
        travel 1.second
        assert_equal 200, HTTParty.get(url, headers: { "X-Token" => "e2e-fake-token" }).code
      end
    end
  end

  test "admin endpoints work through the helper" do
    with_monobank_fake do |fake|
      response = HTTParty.post("#{MonobankFakeHelper::MONOBANK_FAKE_URL}/__fake/cancel_hold",
                               headers: { "X-Fake-Admin" => "1", "Content-Type" => "application/json" },
                               body: JSON.generate(account: "mbf-uah-black", hold_id: "mbf-hold-uklon"))
      assert_equal 200, response.code
      assert_equal 4_212_000, fake.balance("mbf-uah-black")
    end
  end
end
