# Token for the opt-in subscriptions iCal feed (decision 41). NULL means the feed
# is off, which is the default; the partial unique index skips those rows.
class AddSubscriptionsFeedTokenToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :subscriptions_feed_token, :string
    add_index :families, :subscriptions_feed_token, unique: true,
      where: "subscriptions_feed_token IS NOT NULL",
      name: "index_families_on_subscriptions_feed_token"
  end
end
