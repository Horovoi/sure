# frozen_string_literal: true

# A fake of monobank's personal API (https://api.monobank.ua/docs/), for tests and for the
# staging end-to-end run. It speaks the real wire format, so Provider::Monobank cannot tell
# it from the bank:
#
#   GET /personal/client-info                       the client, its cards and its jars
#   GET /personal/statement/{account}/{from}[/{to}] one account's or jar's rows in a window
#
# and it enforces the bank's rules: the X-Token header (unknown token: 403), one request per
# rate_limit_seconds per token and per function (else 429 "Too many requests"), a window of
# at most 31 days + 1 hour (else 400), at most 500 rows per response, newest first.
#
# Admin endpoints (header X-Fake-Admin: 1) change the bank's state while a test runs:
#   POST /__fake/settle_hold  {account, hold_id, settled_id?, amount?}
#   POST /__fake/cancel_hold  {account, hold_id}
#   POST /__fake/add          {account, item}
#   POST /__fake/reset        back to the fixture, log and rate limits cleared
#   GET  /__fake/log          every request with its time and status
#   GET  /__fake/state        accounts and jars with their current balances
#
# Pure Rack and the Ruby standard library: no Rails. The fixture format is described in
# script/monobank_fake/README.md.
require "json"
require "monitor"
require "timeout"
require "digest"
require "rack"

module MonobankFake
  class App
    MAX_STATEMENT_WINDOW = 2_682_000 # seconds: 31 days + 1 hour, as the bank documents
    MAX_STATEMENT_ITEMS = 500
    DEFAULT_RATE_LIMIT_SECONDS = 60
    RATE_LIMIT_ENV = "MONOBANK_FAKE_RATE_LIMIT_SECONDS"
    ADMIN_HEADER = "HTTP_X_FAKE_ADMIN"

    TOO_MANY_REQUESTS = { "errorDescription" => "Too many requests" }.freeze

    STATEMENT_PATH = %r{\A/personal/statement/([^/]+)/(-?\d+)(?:/(-?\d+))?/?\z}
    CLIENT_INFO_PATH = %r{\A/personal/client-info/?\z}

    # Exceptions a fault may raise instead of answering, to play a broken connection. Only
    # these: a fixture must not be able to name an arbitrary constant.
    FAULT_EXCEPTIONS = {
      "Errno::ECONNRESET" => Errno::ECONNRESET,
      "Errno::ECONNREFUSED" => Errno::ECONNREFUSED,
      "EOFError" => EOFError,
      "Timeout::Error" => Timeout::Error
    }.freeze

    ACCOUNT_DEFAULTS = {
      "sendId" => "", "currencyCode" => 980, "cashbackType" => "UAH", "balance" => 0,
      "creditLimit" => 0, "maskedPan" => [], "type" => "black", "iban" => ""
    }.freeze
    JAR_DEFAULTS = {
      "sendId" => "", "title" => "Банка", "description" => "", "currencyCode" => 980,
      "balance" => 0, "goal" => nil
    }.freeze
    # Fields the bank sends only when they have a value
    OPTIONAL_ITEM_FIELDS = %w[comment receiptId invoiceId counterEdrpou counterIban counterName].freeze

    class NotFound < StandardError; end
    class BadRequest < StandardError; end

    attr_reader :fixture, :started_at, :rate_limit_seconds

    # Reads a fixture file (JSON) into a Hash with string keys
    def self.load_fixture(file)
      JSON.parse(File.read(file))
    end

    # fixture: a Hash (string or symbol keys) or the path of a JSON file.
    # clock: returns the current Time; Time.now by default, which follows Rails' travel_to.
    # rate_limit_seconds: overrides ENV MONOBANK_FAKE_RATE_LIMIT_SECONDS and the fixture.
    def initialize(fixture, clock: nil, rate_limit_seconds: nil)
      @fixture = deep_stringify(fixture.is_a?(String) ? self.class.load_fixture(fixture) : fixture)
      @clock = clock || -> { Time.now }
      @rate_limit_override = rate_limit_seconds
      @lock = Monitor.new # re-entrant: HTTP admin calls reach the public methods
      reset!
    end

    def call(env)
      request = Rack::Request.new(env)
      @lock.synchronize { dispatch(request) }
    rescue JSON::ParserError
      json(400, "errorDescription" => "Invalid JSON body")
    end

    # --- State, readable by tests -------------------------------------------------------

    def now
      @clock.call
    end

    # Every request so far: Hashes with at (Float epoch), method, path, function, token,
    # account, from, to, status, rows, early (a 429 for a request sent too soon), fault.
    def requests
      @lock.synchronize { @log.map(&:dup) }
    end

    # Number of 429s answered because a request came before the interval passed
    def early_requests
      requests.count { |entry| entry["early"] }
    end

    # Current balance (minor units) of an account or jar
    def balance(account_id)
      @lock.synchronize { find_product!(account_id)["balance"] }
    end

    # Rows of one account with their balances, newest first, as the bank would send them
    def statement(account_id)
      @lock.synchronize { rendered_items(account_id) }
    end

    # --- Admin operations (also reachable over HTTP under /__fake) ---------------------

    # Back to the fixture: products, rows and faults reloaded, log and rate limits cleared.
    # Relative times (days_ago) count from now.
    def reset!
      @lock.synchronize do
        @started_at = now
        @rate_limit_seconds = resolve_rate_limit
        @tokens = Array(@fixture["tokens"]).map(&:to_s)
        @client = { "clientId" => "fake-client", "name" => "Fake Client", "webHookUrl" => "", "permissions" => "psfj" }
          .merge(@fixture["client"] || {})
        @accounts = Array(@fixture["accounts"]).map { |account| ACCOUNT_DEFAULTS.merge(account) }
        @jars = Array(@fixture["jars"]).map { |jar| JAR_DEFAULTS.merge(jar) }
        (@accounts + @jars).each { |product| product["id"] = product["id"].to_s }
        @statements = Hash.new { |hash, key| hash[key] = [] }
        (@fixture["statements"] || {}).each do |account_id, items|
          product = find_product!(account_id.to_s)
          Array(items).each_with_index do |item, index|
            @statements[product["id"]] << build_item(item, product, index, anchor: @started_at)
          end
        end
        @faults = Array(@fixture["faults"]).map { |fault| { "times" => 1 }.merge(fault) }
        @log = []
        @last_accepted = {}
        self
      end
    end

    # A hold becomes a settled row: by default the same id with hold false (what the bank
    # does); with settled_id the hold row is replaced by a new one. A changed amount moves
    # the account balance by the difference.
    def settle_hold!(account:, hold_id:, settled_id: nil, amount: nil, time: nil)
      @lock.synchronize do
        product = find_product!(account)
        hold = find_item!(product, hold_id, hold: true)
        settled_amount = amount.nil? ? hold["amount"] : Integer(amount)
        product["balance"] += settled_amount - hold["amount"]
        hold["amount"] = settled_amount
        hold["operationAmount"] = settled_amount if hold["currencyCode"] == product["currencyCode"]
        hold["hold"] = false
        hold["id"] = settled_id.to_s if settled_id
        hold["time"] = Integer(time) if time
        hold["_explicit_balance"] = false
        rendered_items(product["id"]).find { |row| row["id"] == hold["id"] }
      end
    end

    # A hold the merchant released: the row disappears and its amount returns
    def cancel_hold!(account:, hold_id:)
      @lock.synchronize do
        product = find_product!(account)
        hold = find_item!(product, hold_id, hold: true)
        @statements[product["id"]].delete(hold)
        product["balance"] -= hold["amount"]
        { "cancelled" => hold_id.to_s }
      end
    end

    # A new row (dated now unless it has time or days_ago, counted from now). The account
    # balance moves by its amount unless the item carries its own balance.
    def add_item!(account:, item:)
      @lock.synchronize do
        product = find_product!(account)
        item = deep_stringify(item)
        seq = @statements[product["id"]].map { |row| row["_seq"] }.max.to_i + 1
        built = build_item({ "time" => now.to_i }.merge(item), product, seq, anchor: now)
        if built["_explicit_balance"]
          product["balance"] = built["balance"]
        else
          product["balance"] += built["amount"]
        end
        @statements[product["id"]] << built
        rendered_items(product["id"]).find { |row| row["id"] == built["id"] }
      end
    end

    private

      def dispatch(request)
        path = request.path_info.to_s
        return admin(request, path) if path.start_with?("/__fake")

        function, match =
          if (match = CLIENT_INFO_PATH.match(path)) then [ "client_info", match ]
          elsif (match = STATEMENT_PATH.match(path)) then [ "statement", match ]
          end
        return json(404, "errorDescription" => "Not found") unless function
        return json(405, "errorDescription" => "Method not allowed") unless request.request_method == "GET"

        entry = { "at" => now.to_f, "method" => request.request_method, "path" => path, "function" => function }
        if function == "statement"
          entry.merge!("account" => match[1], "from" => match[2].to_i, "to" => match[3]&.to_i)
        end
        @log << entry

        status, body = personal(request, function, match, entry)
        entry["status"] = status
        body.is_a?(Exception) ? raise(body) : json(status, body)
      end

      def personal(request, function, match, entry)
        token = request.get_header("HTTP_X_TOKEN").to_s
        return [ 401, { "errorDescription" => "Missing required header 'X-Token'" } ] if token.empty?
        return [ 403, { "errorDescription" => "Unknown 'X-Token'" } ] unless @tokens.include?(token)

        entry["token"] = token
        limit_key = [ token, function ]
        last = @last_accepted[limit_key]
        if last && rate_limit_seconds.positive? && entry["at"] - last < rate_limit_seconds
          entry["early"] = true
          entry["since_previous"] = (entry["at"] - last).round(3)
          return [ 429, TOO_MANY_REQUESTS ]
        end
        entry["since_previous"] = (entry["at"] - last).round(3) if last
        @last_accepted[limit_key] = entry["at"]

        if (fault = take_fault(request.path_info))
          entry["fault"] = true
          return [ fault["status"].to_i, FAULT_EXCEPTIONS.fetch(fault["raise"]).new("fake fault") ] if fault["raise"]

          return [ fault["status"].to_i, fault.fetch("body", { "errorDescription" => "Fake fault" }) ]
        end

        function == "client_info" ? [ 200, client_info ] : statement_response(match, entry)
      rescue BadRequest => e
        [ 400, { "errorDescription" => e.message } ]
      end

      def client_info
        @client.reject { |key, _| key.start_with?("_") }.merge(
          "accounts" => @accounts.map { |account| public_fields(account) },
          "jars" => @jars.map { |jar| public_fields(jar) }
        )
      end

      def statement_response(match, entry)
        account_id = match[1] == "0" ? @accounts.first&.dig("id") : Rack::Utils.unescape_path(match[1])
        from = match[2].to_i
        to = match[3] ? match[3].to_i : entry["at"].to_i
        raise BadRequest, "Invalid account" unless account_id && product(account_id)
        raise BadRequest, "Value of 'to' must be greater than 'from'" if to < from
        raise BadRequest, "Period must be no more than 31 days" if to - from > MAX_STATEMENT_WINDOW

        rows = rendered_items(account_id).select { |item| item["time"].between?(from, to) }.first(MAX_STATEMENT_ITEMS)
        entry["rows"] = rows.size
        [ 200, rows ]
      end

      def admin(request, path)
        return json(404, "errorDescription" => "Not found") unless request.get_header(ADMIN_HEADER) == "1"

        params = request.post? ? parse_body(request) : {}
        result =
          case [ request.request_method, path.chomp("/") ]
          when [ "GET", "/__fake/log" ] then { "requests" => @log.map(&:dup), "early_429" => @log.count { |e| e["early"] } }
          when [ "GET", "/__fake/state" ] then state
          when [ "POST", "/__fake/reset" ] then reset! && { "reset" => true }
          when [ "POST", "/__fake/settle_hold" ]
            settle_hold!(account: params.fetch("account"), hold_id: params.fetch("hold_id"),
                         settled_id: params["settled_id"], amount: params["amount"], time: params["time"])
          when [ "POST", "/__fake/cancel_hold" ]
            cancel_hold!(account: params.fetch("account"), hold_id: params.fetch("hold_id"))
          when [ "POST", "/__fake/add" ]
            add_item!(account: params.fetch("account"), item: params.fetch("item"))
          else
            return json(404, "errorDescription" => "Not found")
          end
        json(200, result)
      rescue KeyError => e
        json(400, "errorDescription" => "Missing #{e.key}")
      rescue NotFound, BadRequest, ArgumentError, TypeError => e
        json(e.is_a?(NotFound) ? 404 : 400, "errorDescription" => e.message)
      end

      def state
        {
          "started_at" => @started_at.to_i,
          "rate_limit_seconds" => rate_limit_seconds,
          "accounts" => @accounts.map { |account| public_fields(account) },
          "jars" => @jars.map { |jar| public_fields(jar) },
          "rows" => @statements.transform_values(&:size)
        }
      end

      def parse_body(request)
        body = request.body&.read.to_s
        body.strip.empty? ? {} : JSON.parse(body)
      end

      def take_fault(path)
        fault = @faults.find do |candidate|
          path.start_with?(candidate["path_prefix"].to_s) && (candidate["times"].nil? || candidate["times"].to_i.positive?)
        end
        fault["times"] -= 1 if fault && fault["times"]
        fault
      end

      def resolve_rate_limit
        value = @rate_limit_override
        value = ENV[RATE_LIMIT_ENV] if value.nil? && ENV[RATE_LIMIT_ENV].to_s != ""
        value = @fixture["rate_limit_seconds"] if value.nil?
        value.nil? ? DEFAULT_RATE_LIMIT_SECONDS : Float(value)
      end

      # A statement row with every field the bank sends. `days_ago` (counted from anchor)
      # wins over `time`; keys starting with "_" are notes for the fixture's reader and are
      # never sent.
      def build_item(item, product, index, anchor:)
        item = deep_stringify(item)
        time =
          if item.key?("days_ago") then (anchor - Float(item["days_ago"]) * 86_400).to_i
          elsif item.key?("time") then Integer(item["time"])
          else raise ArgumentError, "statement item #{item['id'] || index} of #{product['id']} has neither time nor days_ago"
          end
        amount = Integer(item.fetch("amount"))
        mcc = Integer(item.fetch("mcc", 0))
        built = {
          "id" => (item["id"] || "fake-#{product['id']}-#{index}").to_s,
          "time" => time,
          "description" => item.fetch("description", ""),
          "mcc" => mcc,
          "originalMcc" => Integer(item.fetch("originalMcc", mcc)),
          "hold" => item.fetch("hold", false) == true,
          "amount" => amount,
          "operationAmount" => Integer(item.fetch("operationAmount", amount)),
          "currencyCode" => Integer(item.fetch("currencyCode", product["currencyCode"])),
          "commissionRate" => Integer(item.fetch("commissionRate", 0)),
          "cashbackAmount" => Integer(item.fetch("cashbackAmount", 0)),
          "balance" => item.key?("balance") ? Integer(item["balance"]) : nil,
          "_explicit_balance" => item.key?("balance"),
          "_seq" => index
        }
        OPTIONAL_ITEM_FIELDS.each { |field| built[field] = item[field] if item.key?(field) && !item[field].nil? }
        built
      end

      # Rows newest first. A row without a balance of its own gets the balance after it:
      # the account's balance for the newest row, then each older row the balance of the
      # newer one minus that row's amount (holds included: the bank's balance counts them).
      def rendered_items(account_id)
        product = find_product!(account_id)
        ordered = @statements[product["id"]].sort_by { |item| [ -item["time"], -item["_seq"] ] }
        running = product["balance"]
        ordered.map do |item|
          running = item["balance"] if item["_explicit_balance"]
          row = item.reject { |key, _| key.start_with?("_") }.merge("balance" => running)
          running -= item["amount"]
          row
        end
      end

      def find_item!(product, item_id, hold:)
        item = @statements[product["id"]].find { |candidate| candidate["id"] == item_id.to_s }
        raise NotFound, "No row #{item_id} on #{product['id']}" unless item
        raise BadRequest, "Row #{item_id} is not a hold" if hold && !item["hold"]

        item
      end

      def product(account_id)
        (@accounts + @jars).find { |candidate| candidate["id"] == account_id.to_s }
      end

      def find_product!(account_id)
        product(account_id) || raise(NotFound, "No account or jar #{account_id}")
      end

      def public_fields(product)
        product.reject { |key, _| key.start_with?("_") }
      end

      def json(status, body)
        [ status, { "content-type" => "application/json; charset=utf-8" }, [ JSON.generate(body) ] ]
      end

      def deep_stringify(value)
        case value
        when Hash then value.each_with_object({}) { |(key, inner), out| out[key.to_s] = deep_stringify(inner) }
        when Array then value.map { |inner| deep_stringify(inner) }
        else value
        end
      end
  end
end
