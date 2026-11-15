# One request slot of a rate-limited provider API (see Provider::RateLimitable).
# Every write is a single statement, so two processes that reserve the same slot
# at once can never both get it.
class ProviderRateLimitSlot < ApplicationRecord
  validates :provider_key, :scope_key, :bucket, :next_free_at, presence: true

  class << self
    # Takes the slot when it is free (next_free_at <= now) and moves it to
    # now + interval. Returns [true, next_free_at] when taken, or
    # [false, next_free_at] when another request holds it.
    def reserve(provider_key:, scope_key:, bucket:, interval:)
      now = Time.current
      next_free = now + interval.to_f

      sql = sanitize_sql_array([ <<~SQL.squish, provider_key, scope_key, bucket.to_s, next_free, now, now, now ])
        INSERT INTO provider_rate_limit_slots (provider_key, scope_key, bucket, next_free_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (provider_key, scope_key, bucket) DO UPDATE
          SET next_free_at = EXCLUDED.next_free_at, updated_at = EXCLUDED.updated_at
          WHERE provider_rate_limit_slots.next_free_at <= ?
        RETURNING next_free_at
      SQL

      reserved_until = connection.select_value(sql)
      return [ true, cast_time(reserved_until) ] if reserved_until

      [ false, next_free_at(provider_key: provider_key, scope_key: scope_key, bucket: bucket) ]
    end

    # Moves the slot's next free time to until_time, unless it is already later
    def defer(provider_key:, scope_key:, bucket:, until_time:)
      now = Time.current

      sql = sanitize_sql_array([ <<~SQL.squish, provider_key, scope_key, bucket.to_s, until_time, now, now ])
        INSERT INTO provider_rate_limit_slots (provider_key, scope_key, bucket, next_free_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (provider_key, scope_key, bucket) DO UPDATE
          SET next_free_at = GREATEST(provider_rate_limit_slots.next_free_at, EXCLUDED.next_free_at),
              updated_at = EXCLUDED.updated_at
        RETURNING next_free_at
      SQL

      cast_time(connection.select_value(sql))
    end

    # When the slot is next free; now when there is no row yet
    def next_free_at(provider_key:, scope_key:, bucket:)
      where(provider_key: provider_key, scope_key: scope_key, bucket: bucket.to_s).pick(:next_free_at) || Time.current
    end

    private
      def cast_time(value)
        ActiveRecord::Type::DateTime.new.cast(value)&.in_time_zone
      end
  end
end
