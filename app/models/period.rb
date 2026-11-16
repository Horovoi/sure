class Period
  include ActiveModel::Validations, Comparable

  class InvalidKeyError < StandardError; end

  attr_reader :key, :start_date, :end_date

  validates :start_date, :end_date, presence: true, if: -> { PERIODS[key].nil? }
  validates :key, presence: true, if: -> { start_date.nil? || end_date.nil? }
  validate :must_be_valid_date_range

  # The labels are in config/locales/models/period/en.yml, under each key
  PERIODS = {
    "last_day" => {
      date_range: -> { [ 1.day.ago.to_date, Date.current ] }
    },
    "current_week" => {
      date_range: -> { [ Date.current.beginning_of_week, Date.current ] }
    },
    "last_7_days" => {
      date_range: -> { [ 7.days.ago.to_date, Date.current ] }
    },
    "current_month" => {
      date_range: -> { [ Date.current.beginning_of_month, Date.current ] }
    },
    # Shown only when fiscal months are enabled for the family
    "fiscal_current_month" => {
      date_range: -> {
        family = Current.family
        start = if family&.fiscal_month_enabled?
          family.budget_period_start_for(Date.current)
        else
          Date.current.beginning_of_month
        end
        [ start, Date.current ]
      }
    },
    "last_30_days" => {
      date_range: -> { [ 30.days.ago.to_date, Date.current ] }
    },
    "last_90_days" => {
      date_range: -> { [ 90.days.ago.to_date, Date.current ] }
    },
    "current_year" => {
      date_range: -> { [ Date.current.beginning_of_year, Date.current ] }
    },
    "last_365_days" => {
      date_range: -> { [ 365.days.ago.to_date, Date.current ] }
    },
    "last_5_years" => {
      date_range: -> { [ 5.years.ago.to_date, Date.current ] }
    },
    "all_time" => {
      date_range: -> {
        # Anchor one month before the first real activity (a Transaction or
        # Trade), not the oldest entry of any kind: a single old Valuation or
        # opening balance would otherwise stretch every All chart into a long
        # flat line. Only a family with no transactions or trades falls back
        # to oldest_entry_date. A start of today or later is not a meaningful
        # range, so it degrades to the last 5 years.
        family = Current.family
        earliest_activity_date = family&.earliest_activity_date
        start_date = earliest_activity_date ? earliest_activity_date - 1.month : family&.oldest_entry_date
        start_date = 5.years.ago.to_date unless start_date && start_date < Date.current
        [ start_date, Date.current ]
      }
    }
  }

  class << self
    def from_key(key)
      unless PERIODS.key?(key)
        raise InvalidKeyError, "Invalid period key: #{key}"
      end

      start_date, end_date = PERIODS[key].fetch(:date_range).call

      new(key: key, start_date: start_date, end_date: end_date)
    end

    def custom(start_date:, end_date:)
      new(start_date: start_date, end_date: end_date)
    end

    def all
      keys = PERIODS.keys
      # Hide fiscal period unless enabled, but still allow from_key for resilience
      unless Current.family&.fiscal_month_enabled?
        keys = keys - [ "fiscal_current_month" ]
      end
      keys.map { |key| from_key(key) }
    end

    def as_options
      all.map { |period| [ period.label_short, period.key ] }
    end
  end

  PERIODS.each do |key, period|
    define_singleton_method(key) do
      from_key(key)
    end
  end

  def initialize(start_date: nil, end_date: nil, key: nil, date_format: "%b %-d, %Y")
    @key = key
    @start_date = start_date
    @end_date = end_date
    @date_format = date_format
    validate!
  end

  def <=>(other)
    [ start_date, end_date ] <=> [ other.start_date, other.end_date ]
  end

  def date_range
    start_date..end_date
  end

  def days
    (end_date - start_date).to_i + 1
  end

  def within?(other)
    start_date >= other.start_date && end_date <= other.end_date
  end

  def interval
    # Calendar years, so leap days do not move the thresholds: exactly 5
    # years (the 5Y period) is weekly, only a longer range is monthly; a
    # year (1Y) stays daily.
    if end_date > start_date.advance(years: 5)
      "1 month"
    elsif end_date > start_date.advance(years: 1)
      "1 week"
    else
      "1 day"
    end
  end

  def label
    key_metadata ? I18n.t("period.#{key}.label") : I18n.t("period.custom.label")
  end

  def label_short
    key_metadata ? I18n.t("period.#{key}.label_short") : I18n.t("period.custom.label_short")
  end

  def comparison_label
    return I18n.t("period.#{key}.comparison_label") if key_metadata

    I18n.t("period.custom.comparison_label", start: I18n.l(start_date, format: @date_format), end: I18n.l(end_date, format: @date_format))
  end

  private
    def key_metadata
      @key_metadata ||= PERIODS[key]
    end

    def must_be_valid_date_range
      return if start_date.nil? || end_date.nil?
      unless start_date.is_a?(Date) && end_date.is_a?(Date)
        errors.add(:start_date, "must be a valid date, got #{start_date.inspect}")
        errors.add(:end_date, "must be a valid date, got #{end_date.inspect}")
        return
      end

      errors.add(:start_date, "must be before end date") if start_date > end_date
    end
end
