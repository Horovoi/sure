# frozen_string_literal: true

# Writes a fake-bank fixture built around a hand-kept account of the staging copy.
#
#   bin/staging run bin/rails runner script/monobank_fake/generate_fixture.rb -- \
#     --account "Mono Visa" [--family-id ID] [--out tmp/monobank_fixture.json] [--overlap-days 3] [--seed 1]
#
# Reads the database only. Refuses to run unless the database is the staging copy
# (DB_PORT=5433) or the test database. See script/monobank_fake/README.md.
require "optparse"
require_relative "fixture_generator"

module MonobankFake
  module GenerateFixture
    STAGING_DB_PORT = "5433"

    def self.refuse!(message)
      warn "generate_fixture: #{message}"
      exit 1
    end

    def self.guard!
      refuse!("never against production (RAILS_ENV=production)") if Rails.env.production?
      return if Rails.env.test?

      port = ActiveRecord::Base.connection_db_config.configuration_hash[:port].to_s
      unless ENV["DB_PORT"] == STAGING_DB_PORT && port == STAGING_DB_PORT
        refuse!("only on the staging copy (DB_PORT=#{STAGING_DB_PORT}, run it through bin/staging run) or in the test environment; database port is #{port.inspect}")
      end
    end

    def self.parse(argv)
      options = { account: "Mono Visa", family_id: nil, out: "tmp/monobank_fixture.json", overlap_days: 3, seed: 1 }
      OptionParser.new do |parser|
        parser.banner = "Usage: bin/rails runner script/monobank_fake/generate_fixture.rb -- [options]"
        parser.on("--account NAME", "hand-kept account to build around (default Mono Visa)") { |value| options[:account] = value }
        parser.on("--family-id ID", "family, when several have an account with that name") { |value| options[:family_id] = value }
        parser.on("--out FILE", "where to write the fixture (default tmp/monobank_fixture.json)") { |value| options[:out] = value }
        parser.on("--overlap-days N", Integer, "days before the cutover with bank rows for hand entries (0-3, default 3)") { |value| options[:overlap_days] = value }
        parser.on("--seed N", Integer, "random seed for the day shifts and kopecks (default 1)") { |value| options[:seed] = value }
      end.parse!(argv.reject { |arg| arg == "--" })
      options
    end

    def self.find_account(name:, family_id:)
      scope = Account.where(name: name)
      scope = scope.where(family_id: family_id) if family_id
      accounts = scope.to_a
      refuse!("no account named #{name.inspect}") if accounts.empty?
      refuse!("#{accounts.size} accounts named #{name.inspect}; pass --family-id") if accounts.size > 1
      accounts.first
    end

    def self.run(argv)
      guard!
      options = parse(argv)
      account = find_account(name: options[:account], family_id: options[:family_id])
      generator = FixtureGenerator.new(account: account, overlap_days: options[:overlap_days], seed: options[:seed])
      fixture = generator.build

      out = Rails.root.join(options[:out])
      FileUtils.mkdir_p(out.dirname)
      File.write(out, JSON.pretty_generate(fixture))
      expected = fixture["expected"]
      puts "wrote #{out}: cutover #{expected['cutover_date']}, #{expected['claims']} hand-entered entries to claim, " \
           "#{fixture['statements'].values.sum(&:size)} rows on #{fixture['statements'].size} products"
    end
  end
end

MonobankFake::GenerateFixture.run(ARGV) if $PROGRAM_NAME == __FILE__ || $PROGRAM_NAME.end_with?("generate_fixture.rb")
