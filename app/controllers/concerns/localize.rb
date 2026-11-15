module Localize
  extend ActiveSupport::Concern

  included do
    around_action :switch_locale
    around_action :switch_timezone
  end

  private
    # Every source is checked against the supported locales only: a locale that has
    # just a few stray files (Rails' defaults ship many) would serve half-translated pages.
    def switch_locale(&action)
      locale = locale_from_param || locale_from_family || locale_from_accept_language || I18n.default_locale
      I18n.with_locale(locale, &action)
    end

    def locale_from_param
      return unless params[:locale].is_a?(String)

      supported_locale(params[:locale])
    end

    def locale_from_family
      supported_locale(Current.family&.locale)
    end

    def locale_from_accept_language
      header = request.get_header("HTTP_ACCEPT_LANGUAGE")
      return if header.blank?

      parse_accept_language(header).each do |language|
        normalized = normalize_locale(language).downcase
        locale = supported_locales[normalized] || supported_locales[normalized.split("-").first.to_s]
        return locale if locale.present?
      end

      nil
    end

    # The languages of an Accept-Language header, best first. A q-value that is not a
    # number counts as 1, others are clamped to 0..1, and q=0 ("not acceptable") is
    # dropped. Languages with the same q-value keep the order of the header.
    def parse_accept_language(header)
      header.split(",").each_with_index.filter_map do |entry, index|
        language, *attributes = entry.split(";")
        language = language.to_s.strip
        next if language.blank?

        q_param = attributes.map(&:strip).find { |param| param.start_with?("q=") }
        quality = q_param ? (Float(q_param.delete_prefix("q=")) rescue 1.0).clamp(0.0, 1.0) : 1.0
        next if quality.zero?

        [ language, quality, index ]
      end.sort_by { |_, quality, index| [ -quality, index ] }.map(&:first)
    end

    def supported_locale(value)
      return if value.blank?

      supported_locales[normalize_locale(value).downcase]
    end

    # { "pt-br" => :"pt-BR", ... } for the locales that are both supported and loaded.
    def supported_locales
      @supported_locales ||= begin
        supported = LanguagesHelper::SUPPORTED_LOCALES.map(&:to_sym) & I18n.available_locales
        supported.index_by { |locale| normalize_locale(locale).downcase }
      end
    end

    def normalize_locale(locale)
      locale.to_s.strip.tr("_", "-")
    end

    def switch_timezone(&action)
      timezone = Current.family.try(:timezone) || Time.zone
      Time.use_zone(timezone, &action)
    end
end
