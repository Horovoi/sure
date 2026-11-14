# Prepares a benchmark run on the staging copy: signs in as the user with the most
# data (by creating a session, no password needed) and picks the pages to request.
abort "prepare.rb only runs in staging" unless ENV["STAGING_CLONE"] == "1"
require "json"

family = Family.all.max_by { |f| f.entries.count }
user = family.users.find_by(role: %w[admin super_admin]) || family.users.first
session = user.sessions.create!

request = ActionDispatch::Request.new(Rails.application.env_config.merge("HTTP_HOST" => "localhost", "rack.url_scheme" => "http"))
request.cookie_jar.signed[:session_token] = session.id
cookie = request.cookie_jar[:session_token]

accounts = family.accounts.visible.to_a
busiest = accounts.max_by { |a| a.entries.count }
investment = accounts.select { |a| a.accountable_type == "Investment" }.max_by { |a| a.entries.count }
budget = Budget.find_or_bootstrap(family, start_date: Date.current) rescue nil

paths = {
  "dashboard" => "/",
  "transactions" => "/transactions",
  "accounts" => "/accounts",
  "account (busiest)" => (busiest && "/accounts/#{busiest.id}"),
  "account (investment)" => (investment && "/accounts/#{investment.id}"),
  "reports" => "/reports",
  "budget" => (budget && "/budgets/#{budget.to_param}"),
  "subscriptions" => "/subscriptions",
  "categories" => "/categories"
}.compact

File.write("/out/session.json", JSON.generate(cookie: CGI.escape(cookie), paths: paths))
puts "signed in as the user with the most data: #{family.entries.count} entries, #{accounts.size} accounts, #{paths.size} pages"
