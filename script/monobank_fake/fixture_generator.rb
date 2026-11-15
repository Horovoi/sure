# frozen_string_literal: true

require_relative "app"

# Builds a fake-bank fixture around a real hand-kept account (the staging copy of
# "Mono Visa"), so the run checks the link against the owner's own history:
#
# - overlap rows: every hand-entered transaction from cutover - overlap_days to the latest
#   one, same signed amount, about a third of them a day off (as the bank books a purchase
#   a day later or earlier than it was written down); each must claim its entry
# - one row before the cutover that was never entered by hand (must be skipped) and one
#   older than the fetch window (never fetched)
# - new rows from the cutover to now: purchases for the MCC groups, card <-> jar,
#   UAH -> USD and FOP -> card transfers, and two holds
# - the other products (USD, EUR, FOP, two jars) from the sample fixture, dated from now
# - the card's balance and credit limit chosen so the bank's balance equals the
#   hand-kept balance plus the new rows: the cutover day then shows no drift
#
# Amounts of new rows get a few random kopecks (seeded) and are checked against every
# hand-entered amount within 3 days, so no new row can claim a hand-entered entry.
module MonobankFake
  class FixtureGenerator
    SAMPLE = File.expand_path("fixtures/sample.json", __dir__)
    CARD_ID = "mbf-uah-black"
    CLAIM_WINDOW = 3 # days: the first fetch starts at cutover - 3 days, the claim looks 3 days around
    UAH = 980

    # Rows of the card from the cutover on: [key, description, mcc, amount (minor), group, category]
    PURCHASES = [
      [ "atb", "АТБ-Маркет", 5411, -61_250, "groceries", "Groceries" ],
      [ "netflix", "Netflix", 4899, -37_290, "streaming", "Streaming", { "operationAmount" => -899, "currencyCode" => 840 } ],
      [ "lifecell", "lifecell", 4814, -15_000, "mobile_plan", "Mobile Plan" ],
      [ "restaurant", "Пузата Хата", 5812, -27_900, "eating_out", "Eating Out" ],
      [ "bolt", "Bolt", 4121, -14_200, "taxi", "Taxi" ],
      [ "anc", "Аптека АНЦ", 5912, -9_870, "pharmacy", "Pharmacies" ],
      [ "p2p-in", "Від: Олена Петренко", 4829, 150_000, nil, nil, { "comment" => "За квитки" } ],
      [ "novus", "Novus", 5411, -23_480, "groceries", "Groceries" ]
    ].freeze
    # [key, card description, card amount, other product, other description, counterIban on
    # both rows]. Jar rows carry no counterIban at the bank; they read "З чорної картки" /
    # "На чорну картку".
    TRANSFERS = [
      [ "card-to-jar", "На банку «Відпустка»", -100_000, "mbf-jar-vacation", "З чорної картки", false ],
      [ "jar-to-card", "З банки «Відпустка»", 50_000, "mbf-jar-vacation", "На чорну картку", false ],
      [ "uah-to-usd", "Купівля валюти", :usd, "mbf-usd", "Купівля валюти", true ],
      [ "fop-to-card", "Переказ між власними рахунками", 2_000_000, "mbf-fop", "Переказ на картку", true ]
    ].freeze
    HOLDS = [ [ "hold-silpo", "Сільпо", 5411, -38_640 ], [ "hold-uklon", "Uklon", 4121, -12_000 ] ].freeze
    USD_BOUGHT = 100_000 # cents: $1,000

    attr_reader :account, :family, :cutover, :now

    def initialize(account:, overlap_days: CLAIM_WINDOW, seed: 1, now: Time.current, token: "e2e-fake-token", rate_limit_seconds: 60)
      raise ArgumentError, "#{account.name} is in #{account.currency}; the generator builds a UAH card" unless account.currency == "UAH"

      @account = account
      @family = account.family
      @overlap_days = overlap_days.to_i.clamp(0, CLAIM_WINDOW)
      @rng = Random.new(seed)
      @now = now
      @zone = family.resolved_time_zone
      @today = now.in_time_zone(@zone).to_date
      @token = token
      @rate_limit_seconds = rate_limit_seconds
      @cutover = default_cutover_date
    end

    def build
      sample = App.load_fixture(SAMPLE)
      @ibans = sample["accounts"].to_h { |product| [ product["id"], product["iban"] ] }
      @used_amounts = Hash.new { |hash, date| hash[date] = [] }
      overlap = overlap_rows
      skipped = skipped_row
      old = old_row
      new_rows, others = new_card_rows
      card_rows = overlap + [ skipped, old ] + new_rows

      products = sample["accounts"].reject { |product| product["id"] == CARD_ID } + sample["jars"]
      statements = { CARD_ID => card_rows }
      products.each do |product|
        own = Array(sample.dig("statements", product["id"])).reject { |row| row["id"].start_with?("mbf-tr-") }
        statements[product["id"]] = own.map { |row| absolute(row) } + others.fetch(product["id"], [])
      end

      card = card_product(sample, new_rows)
      fixture = {
        "_about" => "Generated #{now.utc.iso8601} from #{account.name} (#{account.id}); cutover #{cutover}. See script/monobank_fake/README.md.",
        "tokens" => [ @token ],
        "rate_limit_seconds" => @rate_limit_seconds,
        "client" => sample["client"],
        "accounts" => [ card ] + sample["accounts"].reject { |product| product["id"] == CARD_ID },
        "jars" => sample["jars"],
        "statements" => statements,
        "faults" => sample["faults"]
      }
      fixture["expected"] = expected(sample, fixture, overlap, card)
      fixture
    end

    # Day after the latest hand-entered entry, at most today (Account::ProviderLink's rule).
    # Today is the family's: the link screen runs in its time zone.
    def default_cutover_date
      if (link = "Account::ProviderLink".safe_constantize) && link.respond_to?(:default_cutover_date)
        return Time.use_zone(@zone) { link.default_cutover_date(account) } || @today
      end

      latest = account.entries.where.not(entryable_type: "Valuation").where("date <= ?", @today).maximum(:date)
      latest ? [ latest + 1, @today ].min : @today
    end

    private

      def usd_rate
        @usd_rate ||= ExchangeRate.where(from_currency: "USD", to_currency: "UAH").where("date <= ? AND rate > 0", @today)
                                  .order(date: :desc).pick(:rate)&.to_d || BigDecimal("41.5")
      end

      def hand_entries
        @hand_entries ||= account.entries.where(entryable_type: "Transaction", currency: account.currency, excluded: false)
                                 .where("date >= ? AND date <= ?", cutover - CLAIM_WINDOW * 2, @today + CLAIM_WINDOW)
                                 .to_a
      end

      # Entries a bank row can claim: no external id, not a generated subscription charge
      def claimable(entry)
        entry.external_id.nil? && entry.source != "subscription"
      end

      def overlap_rows
        first = cutover - @overlap_days
        candidates = hand_entries.select { |entry| claimable(entry) && entry.date >= first && entry.date <= @today }
        candidates.sort_by { |entry| [ entry.date, entry.created_at, entry.id ] }.each_with_index.map do |entry, index|
          shift = @rng.rand < 0.35 ? [ -1, 1 ].sample(random: @rng) : 0
          date = entry.date + shift
          date = entry.date if date < cutover - CLAIM_WINDOW || date > @today
          shift = date - entry.date
          amount = -(entry.amount * 100).round.to_i
          @used_amounts[date] << amount
          {
            "id" => "mbf-ov-#{index + 1}-#{entry.id.to_s[0, 8]}",
            "time" => time_on(date).to_i,
            "description" => entry.name.to_s.truncate(80),
            "mcc" => 5999,
            "amount" => amount,
            "_manual" => { "entry_id" => entry.id, "shift_days" => shift.to_i },
            "_entry_id" => entry.id
          }
        end
      end

      def skipped_row
        date = [ cutover - 2, cutover - CLAIM_WINDOW ].max
        date = [ date, @today ].min
        { "id" => "mbf-skip-not-entered", "time" => time_on(date).to_i, "description" => "Київстар", "mcc" => 4814,
          "amount" => unique_amount(-25_013, date), "_note" => "never entered by hand: skipped before cutover" }
      end

      def old_row
        date = cutover - CLAIM_WINDOW - 3
        { "id" => "mbf-old-before-window", "time" => time_on(date).to_i, "description" => "Сільпо", "mcc" => 5411,
          "amount" => unique_amount(-51_130, date), "_note" => "older than cutover - 3 days: never fetched" }
      end

      # The card's new rows and, per other product, the transfer counterparts
      def new_card_rows
        times = new_row_times(PURCHASES.size + TRANSFERS.size + HOLDS.size)
        rows = []
        others = Hash.new { |hash, key| hash[key] = [] }

        PURCHASES.each do |key, description, mcc, amount, group, category, extra|
          time = times.shift
          row = { "id" => "mbf-new-#{key}", "time" => time.to_i, "description" => description, "mcc" => mcc,
                  "amount" => unique_amount(amount, date_of(time)) }.merge(extra || {})
          if group && category_exists?(category)
            row["_group"] = group
            row["_category"] = category
          end
          rows << row
        end

        TRANSFERS.each do |key, description, amount, other_id, other_description, counter_iban|
          time = times.shift
          if amount == :usd
            uah = -(USD_BOUGHT * usd_rate).round.to_i
            card_amount = unique_amount(uah, date_of(time))
            other_amount = USD_BOUGHT
            extra = { "operationAmount" => -USD_BOUGHT, "currencyCode" => 840 }
          else
            card_amount = unique_amount(amount, date_of(time))
            other_amount = -card_amount
            extra = {}
          end
          other_extra = {}
          if counter_iban
            extra = extra.merge("counterIban" => @ibans.fetch(other_id))
            other_extra = { "counterIban" => @ibans.fetch(CARD_ID) }
          end
          rows << { "id" => "mbf-tr-#{key}", "time" => time.to_i, "description" => description, "mcc" => 4829,
                    "amount" => card_amount, "_group" => "own_transfer", "_category" => nil }.merge(extra)
          others[other_id] << { "id" => "mbf-tr-#{key}-other", "time" => time.to_i, "description" => other_description,
                                "mcc" => 4829, "amount" => other_amount, "_group" => "own_transfer", "_category" => nil }.merge(other_extra)
        end

        HOLDS.each do |key, description, mcc, amount|
          time = times.shift
          rows << { "id" => "mbf-#{key}", "time" => time.to_i, "description" => description, "mcc" => mcc,
                    "amount" => unique_amount(amount, date_of(time)), "hold" => true }
        end

        [ rows, others ]
      end

      # Evenly from the cutover's start (or 08:00 when there is room) to a minute ago
      def new_row_times(count)
        from = @zone.local(cutover.year, cutover.month, cutover.day) + 1.minute
        to = now - 1.minute
        step = (to - from) / (count + 1)
        raise ArgumentError, "only #{(to - from).round}s between the cutover (#{cutover}) and now: run later in the day" if step < 2

        (1..count).map { |index| from + step * index }
      end

      def card_product(sample, new_rows)
        base = sample["accounts"].find { |product| product["id"] == CARD_ID }
        sure_amount = new_rows.sum { |row| -row["amount"] } # Sure sign: positive is an outflow
        if account.accountable_type == "CreditCard"
          owed_minor = (account.balance * 100).round.to_i + sure_amount
          limit = [ 5_000_000, ((owed_minor + 1_000_000) / 1_000_000.0).ceil * 1_000_000 ].max
          base.merge("balance" => limit - owed_minor, "creditLimit" => limit)
        else
          base.merge("balance" => (account.balance * 100).round.to_i - sure_amount, "creditLimit" => 0)
        end
      end

      def expected(sample, fixture, overlap, card)
        balances = sample.dig("expected", "balances").merge(
          CARD_ID => account.accountable_type == "CreditCard" ? (card["creditLimit"] - card["balance"]) / 100.0 : card["balance"] / 100.0
        )
        rows = fixture["statements"].values.flatten
        categories = rows.select { |row| row["_category"] }.group_by { |row| row["_group"] }
        transfers = TRANSFERS.map do |key, _, amount, *|
          amount.is_a?(Integer) && amount.positive? ? { "outflow" => "mbf-tr-#{key}-other", "inflow" => "mbf-tr-#{key}" } : { "outflow" => "mbf-tr-#{key}", "inflow" => "mbf-tr-#{key}-other" }
        end
        {
          "link" => { "account_name" => account.name, "account_id" => account.id, "monobank_account_id" => CARD_ID, "cutover_date" => "auto" },
          "cutover_date" => cutover.iso8601,
          "cutover_adjustment" => 0,
          "claims" => overlap.size,
          "skipped_before_cutover" => 1,
          "never_imported" => [ "mbf-old-before-window" ],
          "pending" => HOLDS.size,
          "pending_ids" => HOLDS.map { |key, *| "mbf-#{key}" },
          "transfers" => transfers.size,
          "transfer_pairs" => transfers,
          "exchange_rates" => [ { "from" => "USD", "to" => "UAH", "rate" => usd_rate.to_f } ] + sample.dig("expected", "exchange_rates").reject { |rate| rate["from"] == "USD" },
          "balances" => balances,
          "account_types" => sample.dig("expected", "account_types").merge(CARD_ID => account.accountable_type),
          "categories" => categories.transform_values(&:size),
          "category_names" => categories.transform_values { |group_rows| group_rows.first["_category"] }
        }
      end

      def category_exists?(name)
        @category_names ||= family.categories.pluck(:name).to_set
        @category_names.include?(name)
      end

      # A sample row with days_ago as an absolute time from now
      def absolute(row)
        row = row.dup
        days = row.delete("days_ago")
        row["time"] = (now - Float(days) * 86_400).to_i if days
        row
      end

      # The amount, moved by a few kopecks until no hand-entered entry within 3 days and no
      # other generated row on that date has it
      def unique_amount(amount, date)
        sign = amount.negative? ? -1 : 1
        candidate = amount + sign * @rng.rand(1..99)
        50.times do
          break unless taken?(candidate, date)

          candidate += sign * @rng.rand(1..99)
        end
        raise ArgumentError, "no free amount near #{amount} on #{date}" if taken?(candidate, date)

        @used_amounts[date] << candidate
        candidate
      end

      def taken?(amount, date)
        sure = BigDecimal(-amount) / 100
        hand_entries.any? { |entry| (entry.date - date).abs <= CLAIM_WINDOW && entry.amount.to_d == sure } ||
          ((date - CLAIM_WINDOW)..(date + CLAIM_WINDOW)).any? { |day| @used_amounts[day].include?(amount) }
      end

      # A time on that day (Kyiv), between 08:00 and 21:00, never later than a minute ago
      def time_on(date)
        start = @zone.local(date.year, date.month, date.day, 8)
        finish = @zone.local(date.year, date.month, date.day, 21)
        finish = [ finish, now - 1.minute ].min
        start = [ start, @zone.local(date.year, date.month, date.day) + 1.minute ].max
        start = @zone.local(date.year, date.month, date.day) + 1.minute if start > finish
        Time.at(start.to_i + @rng.rand([ finish.to_i - start.to_i, 1 ].max)).in_time_zone(@zone)
      end

      def date_of(time)
        time.in_time_zone(@zone).to_date
      end
  end
end
