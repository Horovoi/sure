# frozen_string_literal: true

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "*"

    resource "/api/*",
      headers: :any,
      methods: %i[get post put patch delete options head],
      expose: %w[X-Request-Id X-Runtime],
      max_age: 86_400

    resource "/oauth/*",
      headers: :any,
      methods: %i[get post put patch delete options head],
      expose: %w[X-Request-Id X-Runtime],
      max_age: 86_400

    resource "/sessions/*",
      headers: :any,
      methods: %i[get post delete options head],
      expose: %w[X-Request-Id X-Runtime],
      max_age: 86_400
  end
end
