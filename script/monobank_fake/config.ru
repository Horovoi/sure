# frozen_string_literal: true

# rackup script/monobank_fake/config.ru -o 127.0.0.1 -p 4599
# MONOBANK_FAKE_FIXTURE picks the fixture (default: fixtures/sample.json).
require_relative "app"

run MonobankFake::App.new(ENV.fetch("MONOBANK_FAKE_FIXTURE", File.expand_path("fixtures/sample.json", __dir__)))
