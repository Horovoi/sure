namespace :lunchflow do
  desc "Cleanup stuck pending Lunchflow transactions that already have posted duplicates"
  task cleanup_stuck_pending: :environment do
    puts "Finding stuck pending Lunchflow transactions..."

    stuck_pending = Transaction
      .pending
      .where("transactions.extra -> 'lunchflow' ->> 'pending' = 'true'")
      .includes(:entry)
      .where(entries: { source: "lunchflow" })

    puts "Found #{stuck_pending.count} pending Lunchflow transactions"
    puts

    deleted_count = 0
    kept_count = 0

    stuck_pending.each do |transaction|
      pending_entry = transaction.entry

      posted_match = Entry
        .where(source: "lunchflow")
        .where(account_id: pending_entry.account_id)
        .where(name: pending_entry.name)
        .where(amount: pending_entry.amount)
        .where(currency: pending_entry.currency)
        .where("date BETWEEN ? AND ?", pending_entry.date, pending_entry.date + 8)
        .where("external_id NOT LIKE 'lunchflow_pending_%'")
        .where.not(external_id: nil)
        .where.not(id: pending_entry.id)
        .order(date: :asc)
        .first

      if posted_match
        puts "DELETING duplicate pending entry:"
        puts "  Pending: #{pending_entry.date} | #{pending_entry.name} | #{pending_entry.amount} | #{pending_entry.external_id}"
        puts "  Posted:  #{posted_match.date} | #{posted_match.name} | #{posted_match.amount} | #{posted_match.external_id}"
        pending_entry.destroy!
        deleted_count += 1
        puts "  ✓ Deleted"
        puts
      else
        puts "KEEPING (no posted duplicate found):"
        puts "  #{pending_entry.date} | #{pending_entry.name} | #{pending_entry.amount} | #{pending_entry.external_id}"
        puts
        kept_count += 1
      end
    end

    puts "=" * 80
    puts "Cleanup complete!"
    puts "  Deleted: #{deleted_count} duplicate pending entries"
    puts "  Kept: #{kept_count} entries"
  end
end
