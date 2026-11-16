# Finds the import rows that one account already records, so a statement or CSV
# file that overlaps hand-entered (or subscription-generated) transactions does not
# publish them a second time.
#
# A row matches a Transaction entry of the account in the account currency with the
# same signed amount. Pass 1 takes entries on the same date; pass 2 takes entries up
# to DATE_WINDOW days away, closest date first, then the oldest entry. Each entry
# matches one row at most, so two equal rows against one entry give one match and
# one new row. Names are not compared: a bank's description of a transaction rarely
# matches what was typed by hand.
#
# A row whose date or amount does not parse is never matched, so it is offered for
# import (and the clean step shows the error) instead of disappearing.
#
# Matched entries are only reported, never changed (decision 27).
class Import::DuplicateMatcher
  DATE_WINDOW = 3

  KeyedRow = Data.define(:row, :position, :date, :amount)

  # rows              - Import::Row records of +import+ (any order; row order breaks ties)
  # exclude_entry_ids - entries already used elsewhere (e.g. claimed by an exact-name match)
  # created_before    - only entries created before this time are candidates (the
  #                     publish time, when showing what a finished import skipped)
  def initialize(import:, account:, rows:, exclude_entry_ids: [], created_before: nil)
    @import = import
    @account = account
    @rows = rows
    @exclude_entry_ids = exclude_entry_ids.to_a
    @created_before = created_before
  end

  # { row id => Entry } for every row the account already records
  def matches
    @matches ||= compute_matches
  end

  def matched?(row)
    matches.key?(row.id)
  end

  private
    attr_reader :import, :account, :rows, :exclude_entry_ids, :created_before

    def compute_matches
      return {} if account.nil? || keyed_rows.empty?

      used = Set.new
      result = {}

      match_exact_dates(result, used)
      match_nearby_dates(result, used)

      result
    end

    def match_exact_dates(result, used)
      by_date_and_amount = candidate_entries.group_by { |entry| [ entry.date, entry.amount ] }

      keyed_rows.each do |keyed|
        entry = by_date_and_amount[[ keyed.date, keyed.amount ]]&.find { |candidate| !used.include?(candidate.id) }
        next unless entry

        used << entry.id
        result[keyed.row.id] = entry
      end
    end

    def match_nearby_dates(result, used)
      by_amount = candidate_entries.reject { |entry| used.include?(entry.id) }.group_by(&:amount)

      pairs = keyed_rows.reject { |keyed| result.key?(keyed.row.id) }.flat_map do |keyed|
        (by_amount[keyed.amount] || []).filter_map do |entry|
          gap = (entry.date - keyed.date).to_i.abs
          [ gap, entry, keyed ] if gap <= DATE_WINDOW
        end
      end

      pairs.sort_by! { |gap, entry, keyed| [ gap, entry.created_at, entry.id.to_s, keyed.position ] }

      pairs.each do |_gap, entry, keyed|
        next if used.include?(entry.id) || result.key?(keyed.row.id)

        used << entry.id
        result[keyed.row.id] = entry
      end
    end

    def keyed_rows
      @keyed_rows ||= rows.each_with_index.filter_map do |row, position|
        next unless import.row_currency(row, account) == account.currency

        date = row.parsed_date
        amount = row.parsed_signed_amount
        next if date.nil? || amount.nil?

        KeyedRow.new(row: row, position: position, date: date, amount: amount)
      end
    end

    # One query for the whole window. The import's own entries are left out, so a
    # published import does not match the rows it created.
    def candidate_entries
      @candidate_entries ||= begin
        dates = keyed_rows.map(&:date)

        # A split transaction is the bank line of its parent, never one of its parts
        scope = account.entries
                       .excluding_split_children
                       .where(entryable_type: "Transaction", currency: account.currency)
                       .where(date: (dates.min - DATE_WINDOW)..(dates.max + DATE_WINDOW))
                       .where("entries.import_id IS DISTINCT FROM ?", import.id)
        scope = scope.where.not(id: exclude_entry_ids) if exclude_entry_ids.any?
        scope = scope.where(created_at: ...created_before) if created_before

        scope.order(:created_at, :id).to_a
      end
    end
end
