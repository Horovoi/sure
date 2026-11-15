# An exchange rate multiplies an amount into another currency, so a zero, negative, NaN or
# infinite rate misstates every balance converted with it (a stored zero shows the accounts
# in that currency as worth nothing). ExchangeRate validates this; the constraint covers the
# writes that skip validations, such as the importer's upsert_all.
#
# Such rows are provider glitches, not history worth keeping. Deleting them leaves gaps that
# the next sync fills (ExchangeRate::Importer refetches a range with a missing date), and
# conversions use the nearest stored rate meanwhile. Production had 0 such rows of 187 on
# 14 Nov 2026.
#
# NaN is excluded explicitly because PostgreSQL sorts numeric NaN above every number, so
# `rate > 0` alone accepts it. Infinity is excluded with a text comparison, which works on
# any server version (a numeric 'Infinity' literal needs PostgreSQL 14+).
#
# Added NOT VALID, so this migration holds the ACCESS EXCLUSIVE lock only briefly: new and
# updated rows are checked at once, and ValidatePositiveRateCheckOnExchangeRates scans the
# existing ones in its own transaction under a lighter lock.
class AddPositiveRateCheckToExchangeRates < ActiveRecord::Migration[8.1]
  CONDITION = "rate > 0 AND rate <> 'NaN'::numeric AND rate::text <> 'Infinity'"

  def up
    execute "DELETE FROM exchange_rates WHERE NOT (#{CONDITION})"

    add_check_constraint :exchange_rates, CONDITION, name: "chk_exchange_rates_rate_positive", validate: false
  end

  # The deleted rows were unusable and are not restored
  def down
    remove_check_constraint :exchange_rates, name: "chk_exchange_rates_rate_positive"
  end
end
