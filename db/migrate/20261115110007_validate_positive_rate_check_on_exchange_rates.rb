# Validates the check constraint AddPositiveRateCheckToExchangeRates added NOT VALID. In its
# own migration, so the full-table scan runs after the ACCESS EXCLUSIVE lock from adding the
# constraint is released; VALIDATE CONSTRAINT only takes SHARE UPDATE EXCLUSIVE.
class ValidatePositiveRateCheckOnExchangeRates < ActiveRecord::Migration[8.1]
  def up
    validate_check_constraint :exchange_rates, name: "chk_exchange_rates_rate_positive"
  end

  # A validated constraint cannot be marked NOT VALID again; rolling back the previous
  # migration removes it entirely
  def down
  end
end
