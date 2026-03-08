module Localize
  extend ActiveSupport::Concern

  included do
    around_action :switch_locale
    around_action :switch_timezone
  end

  private
    def switch_locale(&action)
      locale = locale_from_param || locale_from_family || locale_from_accept_language || I18n.default_locale
      I18n.with_locale(locale, &action)
    end

    def locale_from_family
      locale = Current.family&.locale
      return if locale.blank?

      locale_sym = locale.to_sym
      locale_sym if I18n.available_locales.include?(locale_sym)
    end

    def locale_from_accept_language
      header = request.get_header("HTTP_ACCEPT_LANGUAGE")
      return if header.blank?

      parse_accept_language(header).each do |language|
        normalized = normalize_locale(language)
        locale = supported_locales[normalized.downcase]
        return locale if locale.present?

        primary_language = normalized.split("-").first
        primary_locale = supported_locales[primary_language.downcase]
        return primary_locale if primary_locale.present?
      end

      nil
    end

    def parse_accept_language(header)
      header.split(",").map do |entry|
        language, q_part = entry.split(";q=", 2)
        [ language.to_s.strip, q_part.present? ? q_part.to_f : 1.0 ]
      end.reject { |language, _| language.blank? }
        .sort_by { |_, quality| -quality }
        .map(&:first)
    end

    def supported_locales
      @supported_locales ||= I18n.available_locales.each_with_object({}) do |locale, hash|
        normalized = normalize_locale(locale)
        hash[normalized.downcase] = locale
      end
    end

    def normalize_locale(locale)
      locale.to_s.strip.gsub("_", "-")
    end

    def locale_from_param
      return unless params[:locale].is_a?(String) && params[:locale].present?
      locale = params[:locale].to_sym
      locale if I18n.available_locales.include?(locale)
    end

    def switch_timezone(&action)
      timezone = Current.family.try(:timezone) || Time.zone
      Time.use_zone(timezone, &action)
    end
end
