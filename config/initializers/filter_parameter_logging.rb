# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :openai_access_token,
  # One-time codes that act as credentials: MFA TOTP and backup codes and OAuth
  # authorization codes all arrive as "code". Anchored so currency_code and
  # country_code stay readable. invite_code opens registration; the PKCE values
  # and OAuth tokens complete or replay a login.
  /\Acode\z/i, :invite_code, :code_verifier, :code_challenge, :oauth_access_token, :oauth_refresh_token
]
