require "test_helper"

class Import::RowTest < ActiveSupport::TestCase
  setup do
    @import = imports(:transaction)
    @import.update!(
      account: accounts(:depository),
      amount_type_strategy: "custom_column",
      entity_type_col_label: "type",
      signage_convention: nil
    )
  end

  test "an outflow value makes its rows outflows and every other value an inflow" do
    @import.update!(amount_type_outflow_value: "Списання")

    # Sure stores outflows as positive amounts and inflows as negative ones
    assert_equal 120, row(amount: "120", type: "Списання").signed_amount
    assert_equal(-5000, row(amount: "5000", type: "Зарахування").signed_amount)
    assert_equal(-35.5, row(amount: "35.5", type: "Повернення").signed_amount)
  end

  test "an outflow value signs by the type column, not by the sign of the amount" do
    @import.update!(amount_type_outflow_value: "Списання")

    assert_equal 120, row(amount: "-120", type: "Списання").signed_amount
    assert_equal(-35.5, row(amount: "-35.5", type: "Повернення").signed_amount)
  end

  test "an import with only an inflow value signs as before" do
    @import.update!(amount_type_inflow_value: "Зарахування")

    assert_equal(-5000, row(amount: "5000", type: "Зарахування").signed_amount)
    assert_equal 120, row(amount: "120", type: "Списання").signed_amount
    # Legacy behavior: a refund is not the inflow value, so it counts as an outflow
    assert_equal 35.5, row(amount: "35.5", type: "Повернення").signed_amount
  end

  test "signed amount imports ignore the amount type values" do
    @import.update!(amount_type_strategy: "signed_amount", signage_convention: "inflows_positive", amount_type_outflow_value: "Списання")

    assert_equal(-100, row(amount: "100", type: "Списання").signed_amount)
  end

  private
    def row(amount:, type:)
      @import.rows.build(date: "01/01/2024", amount: amount, entity_type: type, name: "Row", currency: "USD")
    end
end
