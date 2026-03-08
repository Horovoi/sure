# frozen_string_literal: true

require "openssl"
require "fileutils"

COMBINED_CA_BUNDLE_PATH = Rails.root.join("tmp", "ssl_ca_bundle.pem").freeze

module SslInitializerHelper
  module_function

  PEM_CERT_BEGIN = "-----BEGIN CERTIFICATE-----"
  PEM_CERT_END = "-----END CERTIFICATE-----"

  def validate_ca_certificate_file(path)
    result = { path: nil, valid: false, error: nil }

    unless File.exist?(path) && File.file?(path) && File.readable?(path)
      result[:error] = "File not found or unreadable: #{path}"
      Rails.logger.warn("[SSL] SSL_CA_FILE invalid: #{path}")
      return result
    end

    content = File.read(path)
    unless content.include?(PEM_CERT_BEGIN) && content.include?(PEM_CERT_END)
      result[:error] = "Invalid PEM certificate"
      Rails.logger.warn("[SSL] SSL_CA_FILE is not valid PEM: #{path}")
      return result
    end

    begin
      pem_blocks = content.scan(/#{PEM_CERT_BEGIN}[\s\S]+?#{PEM_CERT_END}/)
      raise OpenSSL::X509::CertificateError, "No certificates found in PEM file" if pem_blocks.empty?

      pem_blocks.each { |pem| OpenSSL::X509::Certificate.new(pem) }
      result[:path] = path
      result[:valid] = true
      result
    rescue OpenSSL::X509::CertificateError => error
      result[:error] = error.message
      Rails.logger.warn("[SSL] SSL_CA_FILE certificate validation failed: #{error.message}")
      result
    end
  end

  def find_system_ca_bundle
    existing = ENV["SSL_CERT_FILE"]
    return existing if existing.present? && File.exist?(existing) && File.readable?(existing)

    default_file = OpenSSL::X509::DEFAULT_CERT_FILE
    return default_file if default_file.present? && File.exist?(default_file) && File.readable?(default_file)

    nil
  end

  def create_combined_ca_bundle(custom_ca_path, output_path: COMBINED_CA_BUNDLE_PATH)
    system_ca = find_system_ca_bundle
    return nil unless system_ca

    FileUtils.mkdir_p(File.dirname(output_path))
    File.write(output_path, File.read(system_ca) + "\n# Custom CA Certificate\n" + File.read(custom_ca_path))
    output_path.to_s
  rescue => error
    Rails.logger.error("[SSL] Failed to create combined CA bundle: #{error.message}")
    nil
  end
end

Rails.application.configure do
  config.x.ssl ||= ActiveSupport::OrderedOptions.new

  truthy_values = %w[1 true yes on].freeze
  falsy_values = %w[0 false no off].freeze

  debug_env = ENV["SSL_DEBUG"].to_s.strip.downcase
  verify_env = ENV["SSL_VERIFY"].to_s.strip.downcase

  config.x.ssl.debug = truthy_values.include?(debug_env)
  config.x.ssl.verify = !falsy_values.include?(verify_env)
  config.x.ssl.ca_file = nil
  config.x.ssl.ca_file_valid = false

  ca_file = ENV["SSL_CA_FILE"].presence
  if ca_file
    ca_file_status = SslInitializerHelper.validate_ca_certificate_file(ca_file)
    config.x.ssl.ca_file = ca_file_status[:path]
    config.x.ssl.ca_file_valid = ca_file_status[:valid]
    config.x.ssl.ca_file_error = ca_file_status[:error]

    if ca_file_status[:valid]
      combined_path = SslInitializerHelper.create_combined_ca_bundle(ca_file_status[:path])
      if combined_path
        config.x.ssl.combined_ca_bundle = combined_path
        ENV["SSL_CERT_FILE"] = combined_path
      else
        ENV["SSL_CERT_FILE"] = ca_file_status[:path]
      end
    end
  end
end
