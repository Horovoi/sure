# frozen_string_literal: true

module SslConfigurable
  def faraday_ssl_options
    options = {}
    options[:verify] = ssl_verify?
    options[:ca_file] = ssl_ca_file if ssl_ca_file.present?
    options
  end

  def httparty_ssl_options
    options = { verify: ssl_verify? }
    options[:ssl_ca_file] = ssl_ca_file if ssl_ca_file.present?
    options
  end

  def net_http_verify_mode
    ssl_verify? ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
  end

  def ssl_ca_file
    ssl_configuration.ca_file
  end

  def ssl_verify?
    ssl_configuration.verify != false
  end

  def ssl_debug?
    ssl_configuration.debug == true
  end

  private
    def ssl_configuration
      Rails.configuration.x.ssl
    end
end
