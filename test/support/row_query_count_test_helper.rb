# For tests that a list page runs the same queries however many transaction rows it
# shows: a row must read only what the page preloaded or looked up once.
module RowQueryCountTestHelper
  # Queries run, counting those the query cache answers (a row that repeats a query
  # still costs its time), without schema reads and savepoints. The query cache is
  # cleared first: integration requests in one test share it.
  def count_sql_queries(&block)
    ActiveRecord::Base.connection.clear_query_cache
    count = 0
    callback = lambda do |*, payload|
      count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    count
  end

  # One of each row kind a list shows: a categorized and tagged purchase at a merchant
  # with a logo, a reconciled one, a transfer (both legs), a pair the "Transfer?" hint
  # flags, and a one-time expense
  def create_varied_transaction_rows(from:, to:, date: Date.current)
    merchant = from.family.merchants.create!(name: "Shop #{SecureRandom.hex(3)}", logo_url: "https://example.com/logo.png")
    tags = from.family.tags.first(2)
    category = from.family.categories.where(classification: "expense").first

    create_transaction(account: from, date: date, amount: rand(10..99), merchant: merchant, tags: tags, category: category)
    create_transaction(account: from, date: date, amount: rand(10..99)).update!(reconciled_status: "reconciled")
    create_transfer(from_account: from, to_account: to, amount: rand(100..199), date: date)
    hint_amount = rand(200..299)
    create_transaction(account: from, date: date, amount: hint_amount)
    create_transaction(account: to, date: date, amount: -hint_amount)
    create_transaction(account: from, date: date, amount: rand(10..99), kind: "one_time")
  end
end
