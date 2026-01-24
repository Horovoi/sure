# frozen_string_literal: true

namespace :sample_data do
  desc "Generate sample subscription data for development/testing"
  task subscriptions: :environment do
    raise "This task can only be run in development or test environment" unless Rails.env.development? || Rails.env.test?

    family = Family.first
    raise "No family found. Run 'bin/rails demo_data:default' first to create a demo family." unless family

    puts "Generating sample subscriptions for #{family.name}..."

    # Clear existing subscriptions
    existing_count = family.recurring_transactions.subscriptions.count
    if existing_count > 0
      print "Found #{existing_count} existing subscriptions. Delete them? (y/n): "
      if $stdin.gets.chomp.downcase == "y"
        family.recurring_transactions.subscriptions.destroy_all
        puts "Deleted existing subscriptions."
      else
        puts "Keeping existing subscriptions. New ones will be added."
      end
    end

    subscriptions_data = [
      # Streaming (Monthly)
      { name: "Netflix", amount: 15.99, billing_cycle: "monthly", day: 5, category: "Entertainment" },
      { name: "Spotify Premium", amount: 10.99, billing_cycle: "monthly", day: 12, category: "Entertainment" },
      { name: "Hulu", amount: 17.99, billing_cycle: "monthly", day: 18, category: "Entertainment" },
      { name: "Disney+", amount: 13.99, billing_cycle: "monthly", day: 22, category: "Entertainment" },
      { name: "HBO Max", amount: 15.99, billing_cycle: "monthly", day: 8, category: "Entertainment" },
      { name: "YouTube Premium", amount: 13.99, billing_cycle: "monthly", day: 15, category: "Entertainment" },

      # AI/Productivity (Monthly)
      { name: "ChatGPT Plus", amount: 20.00, billing_cycle: "monthly", day: 3, category: "Shopping" },
      { name: "Claude Pro", amount: 20.00, billing_cycle: "monthly", day: 10, category: "Shopping" },
      { name: "Notion", amount: 10.00, billing_cycle: "monthly", day: 25, category: "Shopping" },
      { name: "Figma", amount: 15.00, billing_cycle: "monthly", day: 1, category: "Shopping" },

      # Cloud/Dev Tools (Monthly)
      { name: "GitHub Pro", amount: 4.00, billing_cycle: "monthly", day: 7, category: "Shopping" },
      { name: "iCloud+", amount: 2.99, billing_cycle: "monthly", day: 20, category: "Shopping" },
      { name: "Dropbox Plus", amount: 11.99, billing_cycle: "monthly", day: 14, category: "Shopping" },

      # Yearly Subscriptions
      { name: "Amazon Prime", amount: 139.00, billing_cycle: "yearly", months_until_next: 3, category: "Shopping" },
      { name: "Adobe Creative Cloud", amount: 599.99, billing_cycle: "yearly", months_until_next: 6, category: "Shopping" },
      { name: "Microsoft 365", amount: 99.99, billing_cycle: "yearly", months_until_next: 2, category: "Shopping" },
      { name: "1Password", amount: 35.88, billing_cycle: "yearly", months_until_next: 8, category: "Shopping" },

      # Inactive (cancelled)
      { name: "Crunchyroll", amount: 7.99, billing_cycle: "monthly", day: 28, status: "inactive", category: "Entertainment" },
      { name: "Audible", amount: 14.95, billing_cycle: "monthly", day: 16, status: "inactive", category: "Entertainment" }
    ]

    created_count = 0

    subscriptions_data.each do |data|
      # Find or create category
      category = family.categories.find_by("LOWER(name) LIKE ?", "%#{data[:category].downcase}%")

      # Calculate dates
      today = Date.current

      if data[:billing_cycle] == "yearly"
        # For yearly, use months_until_next to set next_expected_date
        months = data[:months_until_next] || 6
        next_date = today + months.months
        day = next_date.day
        last_date = next_date - 1.year
      else
        # For monthly, use the day field
        day = data[:day] || 15
        # If the day has already passed this month, next billing is next month
        if day <= today.day
          next_date = (today + 1.month).beginning_of_month + (day - 1).days
          last_date = today.beginning_of_month + (day - 1).days
        else
          next_date = today.beginning_of_month + (day - 1).days
          last_date = (today - 1.month).beginning_of_month + (day - 1).days
        end
        # Handle months with fewer days
        next_date = next_date.end_of_month if next_date.day != day
        last_date = last_date.end_of_month if last_date.day != day
      end

      subscription = family.recurring_transactions.create!(
        name: data[:name],
        amount: data[:amount],
        currency: "USD",
        is_subscription: true,
        billing_cycle: data[:billing_cycle],
        expected_day_of_month: day,
        status: data[:status] || "active",
        last_occurrence_date: last_date,
        next_expected_date: next_date,
        category: category
      )

      status_label = subscription.inactive? ? " (inactive)" : ""
      cycle_label = subscription.billing_cycle_yearly? ? "/year" : "/month"
      puts "  Created: #{subscription.name} - $#{subscription.amount}#{cycle_label}#{status_label}"
      created_count += 1
    end

    puts "\nDone! Created #{created_count} sample subscriptions."
    puts "\nSummary:"
    puts "  Active monthly: #{family.recurring_transactions.subscriptions.active.where(billing_cycle: 'monthly').count}"
    puts "  Active yearly: #{family.recurring_transactions.subscriptions.active.where(billing_cycle: 'yearly').count}"
    puts "  Inactive: #{family.recurring_transactions.subscriptions.inactive.count}"

    monthly_total = family.recurring_transactions.subscriptions.active.sum do |sub|
      sub.billing_cycle_yearly? ? (sub.amount / 12) : sub.amount
    end
    puts "  Monthly cost: $#{'%.2f' % monthly_total}"

    puts "\nVisit /subscriptions or /subscriptions/calendar to view them."
  end
end
