module Periodable
  extend ActiveSupport::Concern

  included do
    before_action :set_period
  end

  private
    def set_period
      period_param = params[:period] || Current.user&.default_period

      if period_param == "custom"
        last_30 = Period.last_30_days
        start_date = safe_parse_date(params[:start_date]) || last_30.start_date
        end_date   = safe_parse_date(params[:end_date])   || last_30.end_date

        if start_date > end_date
          start_date, end_date = end_date, start_date
        end

        @period = Period.custom(start_date: start_date, end_date: end_date)
      else
        @period = Period.from_key(period_param)
      end
    rescue Period::InvalidKeyError
      @period = Period.last_30_days
    end

    def safe_parse_date(value)
      return nil if value.blank?
      Date.parse(value)
    rescue ArgumentError
      nil
    end
end
