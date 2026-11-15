# The family's upcoming recurring charges as an iCalendar (RFC 5545) document:
# one all-day event per expected date in the next DAYS days, for the active
# rows the user manages (subscriptions and manual recurring rows). Detected
# patterns, suggestions, dismissed and paused rows are left out.
class RecurringTransaction::IcalFeed
  DAYS = 90
  # Bounds the date walk for a row whose next date lies far in the past
  MAX_STEPS = 500
  # RFC 5545 3.1: content lines are folded at 75 octets
  MAX_LINE_OCTETS = 75
  CRLF = "\r\n".freeze

  attr_reader :family, :today

  def initialize(family, today: nil)
    @family = family
    @today = today || Date.current
  end

  def to_ics
    lines = [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//Sure//Subscriptions//EN",
      "CALSCALE:GREGORIAN",
      "METHOD:PUBLISH",
      "X-WR-CALNAME:#{escape_text(I18n.t("subscriptions.feed.calendar_name"))}",
      "X-PUBLISHED-TTL:PT1H"
    ]
    events.each { |event| lines.concat(event_lines(event)) }
    lines << "END:VCALENDAR"

    lines.map { |line| fold(line) }.join(CRLF) + CRLF
  end

  Event = Data.define(:recurring_transaction, :date)

  def events
    horizon = today + DAYS
    rows.flat_map do |row|
      occurrence_dates(row, horizon).map { |date| Event.new(recurring_transaction: row, date: date) }
    end.sort_by { |event| [ event.date, event.recurring_transaction.display_name.to_s ] }
  end

  # TEXT value escaping (RFC 5545 3.3.11)
  def escape_text(value)
    value.to_s
      .gsub("\\") { "\\\\" }
      .gsub(";") { "\\;" }
      .gsub(",") { "\\," }
      .gsub(/\r\n|\r|\n/) { "\\n" }
  end

  private
    def rows
      family.recurring_transactions.active.user_managed.includes(:merchant, :category).to_a
    end

    def occurrence_dates(row, horizon)
      date = row.next_expected_date
      return [] if date.nil?

      dates = []
      MAX_STEPS.times do
        break if date > horizon

        dates << date if date >= today
        following = row.calculate_next_expected_date(date)
        break if following.nil? || following <= date

        date = following
      end
      dates
    end

    def event_lines(event)
      row = event.recurring_transaction
      [
        "BEGIN:VEVENT",
        "UID:#{row.id}-#{event.date.strftime("%Y%m%d")}@sure",
        "DTSTAMP:#{Time.current.utc.strftime("%Y%m%dT%H%M%SZ")}",
        "DTSTART;VALUE=DATE:#{event.date.strftime("%Y%m%d")}",
        "DTEND;VALUE=DATE:#{(event.date + 1).strftime("%Y%m%d")}",
        "SUMMARY:#{escape_text(summary(row))}",
        "DESCRIPTION:#{escape_text(description(row))}",
        "TRANSP:TRANSPARENT",
        "END:VEVENT"
      ]
    end

    # Outflows are positive amounts; income rows show a plus sign
    def summary(row)
      amount = row.amount_money.abs.format
      amount = "+#{amount}" if row.amount.negative?
      "#{row.display_name}: #{amount}"
    end

    def description(row)
      kind = if row.subscription? && row.billing_cycle_yearly?
        I18n.t("subscriptions.feed.yearly_subscription")
      elsif row.subscription?
        I18n.t("subscriptions.feed.monthly_subscription")
      else
        I18n.t("subscriptions.feed.recurring")
      end
      [ kind, row.category&.name ].compact_blank.join(" · ")
    end

    # Splits a content line into lines of at most 75 octets, each continuation
    # starting with one space, without cutting a UTF-8 character.
    def fold(line)
      return line if line.bytesize <= MAX_LINE_OCTETS

      folded = []
      current = +""
      line.each_char do |char|
        if current.bytesize + char.bytesize > MAX_LINE_OCTETS
          folded << current
          current = +" "
        end
        current << char
      end
      folded << current
      folded.join(CRLF)
    end
end
