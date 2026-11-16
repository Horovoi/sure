# frozen_string_literal: true

# The checks of a monobank run against the fake bank, shared by the staging run
# (script/monobank_fake/e2e.rb) and the integration test
# (test/integration/monobank_end_to_end_test.rb). Needs Rails; reads the fixture's
# `expected` block and its row notes (_manual, _entry_id, _group, _category), see README.md.
#
#   snapshot = MonobankFake::Checks.snapshot(mono_visa)        # before linking
#   ...connect, link, sync...
#   checks = MonobankFake::Checks.new(family:, item:, fixture:, fake:, snapshot:, account: mono_visa)
#   checks.run                                                  # => [Result, ...]
#   checks.report($stdout)                                      # PASS/FAIL lines
require_relative "app"

module MonobankFake
  class Checks
    Result = Struct.new(:name, :ok, :detail, keyword_init: true) do
      def to_s
        "#{ok ? 'PASS' : 'FAIL'}  #{name}#{detail.to_s.empty? ? '' : " (#{detail})"}"
      end
    end

    # Balance columns compared before and after linking. The generated end_* columns are
    # derived from these, end_balance is compared too as the figure the user sees.
    BALANCE_COLUMNS = %w[date currency balance cash_balance start_cash_balance start_non_cash_balance
                         cash_inflows cash_outflows non_cash_inflows non_cash_outflows net_market_flows
                         cash_adjustments non_cash_adjustments flows_factor end_balance].freeze
    DUPLICATE_WINDOW = 3 # days, as Import::DuplicateMatcher
    SOURCE = "monobank"

    # What the account looks like before the bank is linked: every balance row and every
    # entry (id, date, amount, name). Compared after the run for the days before the cutover.
    def self.snapshot(account)
      account.reload
      {
        account_id: account.id,
        balance: account.balance,
        balances: account.balances.order(:date, :currency).pluck(*BALANCE_COLUMNS).map { |row| BALANCE_COLUMNS.zip(row).to_h },
        entries: account.entries.order(:date, :id).pluck(:id, :date, :amount, :currency, :entryable_type)
                        .map { |id, date, amount, currency, type| { id: id, date: date, amount: amount, currency: currency, type: type } }
      }
    end

    attr_reader :family, :item, :fixture, :fake, :snapshot, :account, :results

    # fake: the MonobankFake::App (its request log is checked). interval: the client's
    # MONOBANK_MIN_REQUEST_INTERVAL, for the "interval respected" check.
    # since: only syncs created from then on are checked (a staging copy keeps old ones).
    def initialize(family:, item:, fixture:, fake:, snapshot:, account:, interval: nil, since: nil, now: -> { Time.current })
      @family = family
      @item = item
      @fixture = fixture
      @fake = fake
      @snapshot = snapshot
      @account = account
      @interval = interval
      @now = now
      @since = since
      @results = []
    end

    def expected
      fixture.fetch("expected", {})
    end

    def passed?
      results.any? && results.all?(&:ok)
    end

    def failures
      results.reject(&:ok)
    end

    def report(io = $stdout)
      results.each { |result| io.puts(result.to_s) }
      io.puts(passed? ? "PASS: all #{results.size} checks" : "FAIL: #{failures.size} of #{results.size} checks failed")
      passed?
    end

    # Runs every check; pending:, balances: and jar_goals: override the fixture's
    # expectation (after the test settles or cancels holds, or changes jars, in the fake).
    def run(pending: nil, pending_ids: nil, balances: nil, gone: [], settled: [], jar_goals: nil)
      @results = []
      @account.reload
      check_link
      check_no_duplicate_external_ids
      check_no_duplicate_pairs
      check_history_before_cutover
      check_cutover
      check_balances(balances || expected.fetch("balances", {}))
      check_account_types
      check_pending(pending || expected["pending"], pending_ids || expected["pending_ids"])
      check_gone(gone)
      check_settled(settled)
      check_claims
      check_skipped_before_cutover
      check_never_imported
      check_every_row_imported(gone)
      check_transfers
      check_categories
      check_jar_goals(jar_goals || expected["jar_goals"])
      check_rate_limit
      check_syncs
      check_fetch_finished
      results
    end

    # Adds a result from outside the standard checks
    def add(name, ok, detail = nil)
      record(name, ok, detail)
    end

    # --- Lookups ---------------------------------------------------------------------

    def monobank_accounts
      MonobankAccount.where(monobank_item_id: item.id).to_a
    end

    def monobank_account(fake_id)
      monobank_accounts.find { |candidate| candidate.account_id.to_s == fake_id.to_s }
    end

    def sure_account(fake_id)
      monobank_account(fake_id)&.current_account
    end

    def linked_accounts
      monobank_accounts.filter_map(&:current_account)
    end

    # Entries of the family that carry this bank row (its id is the external id, or the
    # end of it: the core may prefix it)
    def entries_for(row_id)
      Entry.joins(:account).where(accounts: { family_id: family.id })
           .where("entries.external_id = :id OR entries.external_id LIKE :suffix", id: row_id.to_s, suffix: "%#{Entry.sanitize_sql_like(row_id.to_s)}")
           .to_a
    end

    def rows(fake_id = nil)
      statements = fixture.fetch("statements", {})
      fake_id ? Array(statements[fake_id.to_s]) : statements.values.flatten
    end

    def row_time(row)
      return (fake.started_at - Float(row["days_ago"]) * 86_400).to_i if row.key?("days_ago")

      Integer(row["time"])
    end

    def row_date(row)
      Time.at(row_time(row)).in_time_zone(family.resolved_time_zone).to_date
    end

    def linked_fake_id
      expected.dig("link", "monobank_account_id")
    end

    def cutover_date
      @account.provider_cutover_date
    end

    # Entries the bank still holds as pending (Entry.pending_from, framework)
    def pending_entries
      Entry.pending_from(SOURCE)
    end

    private

      def record(name, ok, detail = nil)
        @results << Result.new(name: name, ok: ok ? true : false, detail: detail)
      end

      def check_link
        mono = monobank_account(linked_fake_id)
        linked = mono && mono.current_account&.id == @account.id
        record("#{@account.name} linked to #{linked_fake_id}", linked,
               linked ? "cutover #{cutover_date}" : "linked to #{mono&.current_account&.name.inspect}")
        expected_accounts = (Array(fixture["accounts"]) + Array(fixture["jars"])).map { |product| product["id"].to_s }
        missing = expected_accounts.reject { |id| sure_account(id) }
        record("every product has a linked account", missing.empty?, missing.empty? ? "#{expected_accounts.size} products" : "missing #{missing.join(', ')}")
      end

      def check_no_duplicate_external_ids
        duplicates = Entry.joins(:account).where(accounts: { family_id: family.id }).where(source: SOURCE)
                          .where.not(external_id: nil).group(:external_id).having("COUNT(*) > 1").count
        record("no external id imported twice", duplicates.empty?, duplicates.keys.first(5).join(", ").presence)
      end

      # A manual entry (no external id) and a new bank entry with the same amount within
      # 3 days of each other: the claim should have joined them.
      def check_no_duplicate_pairs
        pairs = linked_accounts.sum do |linked|
          entries = linked.entries.where(entryable_type: "Transaction").to_a
          manual = entries.select { |entry| entry.external_id.nil? }
          imported = entries.select { |entry| entry.source == SOURCE && entry.external_id.present? && !claimed?(entry) && !pending?(entry) }
          manual.sum do |entry|
            imported.count { |other| other.amount == entry.amount && other.currency == entry.currency && (other.date - entry.date).abs <= DUPLICATE_WINDOW }
          end
        end
        record("no manual and bank entry left as duplicates (same amount within #{DUPLICATE_WINDOW} days)", pairs.zero?, "#{pairs} pairs")
      end

      def check_history_before_cutover
        cutover = cutover_date
        unless cutover
          record("history before the cutover unchanged", false, "no cutover date on #{@account.name}")
          return
        end

        before = snapshot[:balances].select { |row| row["date"] < cutover }
        after = @account.balances.where("date < ?", cutover).order(:date, :currency).pluck(*BALANCE_COLUMNS).map { |row| BALANCE_COLUMNS.zip(row).to_h }
        changed = before.zip(after).reject { |old, new| old == new }
        changed_detail = changed.first&.then { |old, new| "first difference #{old&.fetch('date')}: #{diff(old, new)}" }
        record("balances before the cutover identical (#{before.size} days)", before.size == after.size && changed.empty?,
               before.size == after.size ? changed_detail : "#{before.size} days before, #{after.size} after")

        current = @account.entries.where(id: snapshot[:entries].map { |entry| entry[:id] }).pluck(:id, :date, :amount).to_h { |id, date, amount| [ id, [ date, amount ] ] }
        moved = snapshot[:entries].reject { |entry| current[entry[:id]] == [ entry[:date], entry[:amount] ] }
        record("hand-entered entries kept with their dates and amounts (#{snapshot[:entries].size})", moved.empty?,
               moved.first(3).map { |entry| "#{entry[:date]} #{entry[:amount]}" }.join(", ").presence)
      end

      # Generated fixtures know the cutover and make the bank's balance agree with the
      # hand-kept one, so the cutover day must show no adjustment
      def check_cutover
        if (date = expected["cutover_date"])
          record("cutover date #{date}", cutover_date.to_s == date.to_s, "got #{cutover_date.inspect}")
        end
        return if expected["cutover_adjustment"].nil? || cutover_date.nil?

        row = @account.balances.find_by(date: cutover_date, currency: @account.currency)
        adjustment = row&.cash_adjustments
        ok = adjustment && (adjustment.to_d - expected["cutover_adjustment"].to_d).abs < BigDecimal("0.005")
        record("cutover day adjustment #{expected['cutover_adjustment']}", ok, row ? "got #{adjustment}" : "no balance row on #{cutover_date}")
      end

      def check_balances(balances)
        balances.each do |fake_id, amount|
          linked = sure_account(fake_id)
          actual = linked&.reload&.balance
          ok = actual && (actual.to_d - amount.to_d).abs < BigDecimal("0.005")
          record("current balance #{fake_id} = #{format('%.2f', amount)}", ok, actual.nil? ? "no account" : "got #{format('%.2f', actual)} #{linked.currency}")
        end
      end

      def check_account_types
        expected.fetch("account_types", {}).each do |fake_id, type|
          actual = sure_account(fake_id)&.accountable_type
          record("#{fake_id} is a #{type}", actual == type, actual == type ? nil : "got #{actual.inspect}")
        end
      end

      def check_pending(count, ids)
        return if count.nil?

        pending = pending_entries.where(account_id: linked_accounts.map(&:id)).to_a
        record("pending holds: #{count}", pending.size == count, "got #{pending.size}")
        Array(ids).each do |row_id|
          found = entries_for(row_id)
          record("hold #{row_id} is one pending entry", found.size == 1 && pending?(found.first), "#{found.size} entries#{found.first && !pending?(found.first) ? ', not pending' : ''}")
        end
      end

      def check_gone(row_ids)
        Array(row_ids).each do |row_id|
          found = entries_for(row_id)
          record("#{row_id} has no entry", found.empty?, found.empty? ? nil : "#{found.size} entries")
        end
      end

      def check_settled(row_ids)
        Array(row_ids).each do |row_id|
          found = entries_for(row_id)
          record("settled hold #{row_id} is one entry, no longer pending", found.size == 1 && !pending?(found.first), "#{found.size} entries")
        end
      end

      def check_claims
        claimed = @account.entries.to_a.select { |entry| claimed?(entry) }
        count = expected["claims"]
        record("hand-entered entries claimed by bank rows: #{count}", count.nil? || claimed.size == count, "got #{claimed.size}") unless count.nil?

        manual_rows = rows(linked_fake_id).select { |row| row["_manual"] }
        expected_ids = manual_rows.filter_map { |row| row["_entry_id"] || row.dig("_manual", "entry_id") }
        if expected_ids.any?
          missing = expected_ids - claimed.map(&:id)
          record("each claimed entry is the hand-entered one", missing.empty?, missing.empty? ? nil : "#{missing.size} not claimed")
        end
        manual_rows.each do |row|
          found = entries_for(row["id"])
          record("bank row #{row['id']} joined a hand-entered entry", found.size == 1 && claimed?(found.first),
                 found.empty? ? "no entry" : "#{found.size} entries")
        end
      end

      def check_skipped_before_cutover
        count = expected["skipped_before_cutover"]
        return if count.nil? || cutover_date.nil?

        never = Array(expected["never_imported"])
        skipped = rows(linked_fake_id).select do |row|
          !row["_manual"] && !never.include?(row["id"]) && !row["hold"] && row_date(row) < cutover_date && entries_for(row["id"]).empty?
        end
        record("bank rows before the cutover not imported: #{count}", skipped.size == count, "got #{skipped.size}")
      end

      def check_never_imported
        Array(expected["never_imported"]).each do |row_id|
          record("#{row_id} (before the fetch window) not imported", entries_for(row_id).empty?)
        end
      end

      def check_transfers
        pairs = Array(expected["transfer_pairs"])
        found = pairs.count do |pair|
          outflow = entries_for(pair["outflow"]).first
          inflow = entries_for(pair["inflow"]).first
          transfer = outflow && inflow && Transfer.find_by(outflow_transaction_id: outflow.entryable_id, inflow_transaction_id: inflow.entryable_id)
          kinds = transfer && [ outflow.entryable.reload.kind, inflow.entryable.reload.kind ]
          ok = transfer&.pending? && kinds == %w[standard standard]
          detail = if transfer.nil? then outflow && inflow ? "no suggestion" : "missing entry"
          elsif !transfer.pending? then "status #{transfer.status}"
          elsif kinds != %w[standard standard] then "kinds #{kinds.join('/')} before confirm"
          end
          record("transfer suggested #{pair['outflow']} -> #{pair['inflow']}", ok, detail)
          ok
        end
        return unless expected["transfers"]

        record("pending transfers suggested: at least #{expected['transfers']}", found >= expected["transfers"], "got #{found}")
      end

      def check_categories
        annotated = rows.select { |row| row.key?("_category") }
        annotated.each do |row|
          entry = entries_for(row["id"]).first
          actual = entry&.entryable&.category&.name
          record("category of #{row['id']} (#{row['_group']}): #{row['_category'] || 'none'}", entry && actual == row["_category"],
                 entry ? "got #{actual || 'none'}" : "no entry")
        end
        expected.fetch("categories", {}).each do |group, count|
          group_rows = annotated.select { |row| row["_group"] == group }
          got = group_rows.count { |row| row["_category"] && entries_for(row["id"]).first&.entryable&.category&.name == row["_category"] }
          record("group #{group}: #{count} categorised", got == count, "got #{got}")
        end
      end

      # Each jar with a target is one goal funded by the whole of its account, with the
      # expected name and target in the jar's currency; a jar without one (null) has none;
      # no card or currency account was given a goal
      def check_jar_goals(jar_goals)
        return if jar_goals.nil?

        jar_goals.each do |fake_id, want|
          mono = monobank_account(fake_id)
          linked = mono&.current_account
          goals = linked ? Goal.joins(:goal_accounts).where(goal_accounts: { account_id: linked.id }).distinct.to_a : []
          if want.nil?
            record("jar #{fake_id} without a target has no goal", linked && goals.empty? && mono.linked_goal_id.nil?,
                   linked ? "#{goals.size} goals" : "no account")
            next
          end

          goal = goals.first
          links = goal ? goal.goal_accounts.map { |link| [ link.account_id, link.allocated_amount ] } : []
          ok = goals.size == 1 && mono.linked_goal_id == goal.id && goal.name == want["name"] &&
               (goal.target_amount.to_d - want["target"].to_d).abs < BigDecimal("0.005") &&
               goal.currency == linked.currency && links == [ [ linked.id, nil ] ]
          detail = if goal.nil? then linked ? "no goal" : "no account"
          else "#{goals.size} goals; #{goal.name.inspect} #{goal.target_amount.to_d.round(2)} #{goal.currency}, #{links.size} links, linked #{mono.linked_goal_id == goal.id}"
          end
          record("jar #{fake_id}: goal #{want['name'].inspect}, target #{format('%.2f', want['target'])}", ok, detail)
        end

        jar_ids = Array(fixture["jars"]).map { |jar| jar["id"].to_s }
        with_goal = monobank_accounts.reject { |mono| jar_ids.include?(mono.account_id.to_s) }.select(&:linked_goal_id)
        record("no goal for a card or currency account", with_goal.empty?, with_goal.map(&:account_id).join(", ").presence)
      end

      def check_rate_limit
        log = fake.requests
        early = log.count { |entry| entry["early"] }
        record("no request before the rate limit allowed it (#{log.size} requests)", early.zero?, "#{early} early 429s")
        return unless @interval

        gaps = log.select { |entry| entry["since_previous"] && !entry["early"] }.map { |entry| entry["since_previous"] }
        shortest = gaps.min
        record("requests per token and function at least #{@interval}s apart", shortest.nil? || shortest >= @interval.to_f - 0.001,
               shortest && "shortest #{shortest.round(2)}s")
      end

      def check_syncs
        syncables = [ item ] + linked_accounts + [ family ]
        syncs = syncables.flat_map { |syncable| syncable.syncs.to_a }
        syncs.select! { |sync| sync.created_at >= @since } if @since
        open = syncs.select { |sync| %w[pending syncing].include?(sync.status) }
        long = open.select { |sync| sync.created_at < @now.call - Sync::STALE_AFTER }
        record("no sync open longer than #{Sync::STALE_AFTER.inspect}", long.empty?, "#{long.size} of #{open.size} open")
        bad = syncs.select { |sync| %w[failed stale].include?(sync.status) }
        record("no failed or stale sync (#{syncs.size} syncs)", bad.empty?, bad.first(3).map { |sync| "#{sync.syncable_type} #{sync.status}: #{sync.error.to_s.truncate(80)}" }.join("; ").presence)
      end

      # The chain has ended. A forward window may still be due (an open hold keeps one due
      # for the next hourly sync); whether the history is complete is check_every_row_imported.
      def check_fetch_finished
        progress = item.reload.backfill_progress
        next_window = MonobankItem::FetchPlan.new(item).next_window
        ok = !progress[:chain_active] && (next_window.nil? || next_window.kind.to_s == "forward")
        record("statement fetch chain finished", ok,
               "chain_active #{progress[:chain_active]}, windows_remaining #{progress[:windows_remaining]}, next #{next_window&.kind.inspect}")
      end

      # Every bank row the run should bring in has exactly one entry: all products' rows,
      # except rows older than the fetch window, rows before the cutover that were never
      # entered by hand, and holds the bank cancelled
      def check_every_row_imported(gone)
        never = Array(expected["never_imported"]) + Array(gone)
        wanted = fixture.fetch("statements", {}).flat_map do |fake_id, product_rows|
          product_rows.reject do |row|
            never.include?(row["id"]) ||
              (fake_id == linked_fake_id && cutover_date && !row["_manual"] && !row["hold"] && row_date(row) < cutover_date)
          end
        end
        counts = wanted.to_h { |row| [ row["id"], entries_for(row["id"]).size ] }
        missing = counts.select { |_, count| count.zero? }.keys
        doubled = counts.select { |_, count| count > 1 }.keys
        record("every bank row has one entry (#{wanted.size} rows)", missing.empty? && doubled.empty?,
               [ ("missing #{missing.first(5).join(', ')}#{missing.size > 5 ? " and #{missing.size - 5} more" : ''}" if missing.any?),
                 ("twice #{doubled.first(5).join(', ')}" if doubled.any?) ].compact.join("; ").presence)
      end

      # A claimed entry carries the claim in its transaction's extra (ProviderImportAdapter)
      def claimed?(entry)
        entry.entryable.respond_to?(:extra) && entry.entryable.extra.to_h["provider_claim"].present?
      end

      def pending?(entry)
        pending_entries.where(id: entry.id).exists?
      end

      def diff(old, new)
        return "missing after" if new.nil?

        (old.keys | new.keys).reject { |key| old[key] == new[key] }.map { |key| "#{key} #{old[key]} -> #{new[key]}" }.join(", ")
      end
  end
end
