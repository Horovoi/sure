# Finds the existing entries a provider's new transactions already record, so linking
# an account that has manual or imported history does not double it. The provider then
# takes the entry over (Account::ProviderImportAdapter) instead of creating a new one.
#
# Same rules as Import::DuplicateMatcher: a row matches a Transaction entry of the
# account in the account currency with the same signed amount. Pass 1 takes entries on
# the same date; pass 2 takes entries up to `window` days away, closest date first, then
# the oldest entry, then row order. Names are not compared.
#
# Candidates are entries the user recorded: no external_id, or one from a manual source
# (Entry::MANUAL_SOURCES, e.g. an idempotency key given through the assistant), so an
# entry a provider already owns is never claimed again. They are not generated
# subscription charges (the subscription reconciler owns those), not excluded, not
# pending holds and carry no provider_claim marker. A split transaction is claimed as
# its parent (the line the bank shows), never as one of its parts. A row in another currency never
# matches. Each entry and each row is used once.
#
# Pending rows match too, so the entry a hold stands for is never handed to another
# row; Account::ProviderImportAdapter does not book such a hold, and its settled row
# claims the entry.
#
#   claimer = Account::ProviderEntryClaimer.new(account, source: "monobank")
#   claimer.match([ Account::ProviderEntryClaimer::Row.new(key: "tx-1", date:, amount:, currency: "UAH", pending: false) ])
#   # => { "tx-1" => #<Entry ...> }
class Account::ProviderEntryClaimer
  Row = Data.define(:key, :date, :amount, :currency, :pending)

  def initialize(account, source:, window: Import::DuplicateMatcher::DATE_WINDOW)
    @account = account
    @source = source.to_s
    @window = window
  end

  # { row.key => Entry } for the rows the account already records. One query for the
  # date span of all rows.
  def match(rows)
    keyed = rows.each_with_index.filter_map do |row, position|
      next if row.date.nil? || row.amount.nil?
      next unless row.currency.to_s.upcase == account.currency.to_s.upcase

      [ row, position, row.date.to_date, row.amount.to_d ]
    end
    return {} if keyed.empty?

    candidates = candidate_entries(keyed.map { |_row, _position, date, _amount| date })
    return {} if candidates.empty?

    used = Set.new
    result = {}

    by_date_and_amount = candidates.group_by { |entry| [ entry.date, entry.amount.to_d ] }
    keyed.each do |row, _position, date, amount|
      entry = by_date_and_amount[[ date, amount ]]&.find { |candidate| !used.include?(candidate.id) }
      next unless entry

      used << entry.id
      result[row.key] = entry
    end

    by_amount = candidates.reject { |entry| used.include?(entry.id) }.group_by { |entry| entry.amount.to_d }
    pairs = keyed.reject { |row, *| result.key?(row.key) }.flat_map do |row, position, date, amount|
      (by_amount[amount] || []).filter_map do |entry|
        gap = (entry.date - date).to_i.abs
        [ gap, entry, row, position ] if gap <= window
      end
    end
    pairs.sort_by! { |gap, entry, _row, position| [ gap, entry.created_at, entry.id.to_s, position ] }

    pairs.each do |_gap, entry, row, _position|
      next if used.include?(entry.id) || result.key?(row.key)

      used << entry.id
      result[row.key] = entry
    end

    result
  end

  def match_one(row)
    match([ row ])[row.key]
  end

  # Whether entry's external id still leaves it to the user (none, or a manual source's)
  def self.claimable_id?(entry)
    entry.external_id.nil? || entry.source.in?(Entry::MANUAL_SOURCES)
  end

  private
    attr_reader :account, :source, :window

    def candidate_entries(dates)
      account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(currency: account.currency)
        # The bank's line of a split transaction is its parent (excluded only because it
        # is split), never one of its parts
        .where(parent_entry_id: nil)
        .where("entries.excluded = false OR EXISTS (SELECT 1 FROM entries split_children WHERE split_children.parent_entry_id = entries.id)")
        .where("entries.external_id IS NULL OR entries.source IN (?)", Entry::MANUAL_SOURCES)
        .where(date: (dates.min - window)..(dates.max + window))
        .where("entries.source IS DISTINCT FROM ?", "subscription")
        .where.not(Transaction.pending_sql("transactions"))
        .where("(transactions.extra -> 'provider_claim') IS NULL")
        .order(:created_at, :id)
        .to_a
    end
end
