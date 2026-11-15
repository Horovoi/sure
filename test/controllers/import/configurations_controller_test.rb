require "test_helper"

class Import::ConfigurationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @import = imports(:transaction)
  end

  test "show" do
    get import_configuration_url(@import)
    assert_response :success
  end

  test "updating a valid configuration regenerates rows" do
    TransactionImport.any_instance.expects(:generate_rows_from_csv).once

    patch import_configuration_url(@import), params: {
      import: {
        date_col_label: "Date",
        date_format: "%Y-%m-%d",
        name_col_label: "Name",
        category_col_label: "Category",
        tags_col_label: "Tags",
        amount_col_label: "Amount",
        signage_convention: "inflows_positive",
        account_col_label: "Account",
        number_format: "1.234,56"
      }
    }

    assert_redirected_to import_clean_url(@import)
    assert_equal "Import configured successfully.", flash[:notice]

    # Verify configurations were saved
    @import.reload
    assert_equal "Date", @import.date_col_label
    assert_equal "%Y-%m-%d", @import.date_format
    assert_equal "Name", @import.name_col_label
    assert_equal "Category", @import.category_col_label
    assert_equal "Tags", @import.tags_col_label
    assert_equal "Amount", @import.amount_col_label
    assert_equal "inflows_positive", @import.signage_convention
    assert_equal "Account", @import.account_col_label
    assert_equal "1.234,56", @import.number_format
  end

  test "an outflow value of the amount type column saves" do
    TransactionImport.any_instance.stubs(:generate_rows_from_csv)

    patch import_configuration_url(@import), params: {
      import: {
        amount_type_strategy: "custom_column",
        entity_type_col_label: "Type",
        amount_type_outflow_value: "Списання"
      }
    }

    assert_redirected_to import_clean_url(@import)
    @import.reload
    assert_equal "custom_column", @import.amount_type_strategy
    assert_equal "Списання", @import.amount_type_outflow_value
    assert_nil @import.amount_type_inflow_value
  end

  test "the form's value and meaning write the matching column and clear the other" do
    TransactionImport.any_instance.stubs(:generate_rows_from_csv)
    @import.update!(amount_type_strategy: "custom_column", entity_type_col_label: "Type", amount_type_inflow_value: "Зарахування")

    patch import_configuration_url(@import), params: {
      import: { amount_type_strategy: "custom_column", entity_type_col_label: "Type", amount_type_value: "Списання", amount_type_direction: "outflow" }
    }

    @import.reload
    assert_equal "Списання", @import.amount_type_outflow_value
    assert_nil @import.amount_type_inflow_value

    patch import_configuration_url(@import), params: {
      import: { amount_type_strategy: "custom_column", entity_type_col_label: "Type", amount_type_value: "Зарахування", amount_type_direction: "inflow" }
    }

    @import.reload
    assert_equal "Зарахування", @import.amount_type_inflow_value
    assert_nil @import.amount_type_outflow_value
  end

  test "both amount type values at once are rejected" do
    TransactionImport.any_instance.expects(:generate_rows_from_csv).never

    patch import_configuration_url(@import), params: {
      import: { amount_type_strategy: "custom_column", entity_type_col_label: "Type", amount_type_inflow_value: "Зарахування", amount_type_outflow_value: "Списання" }
    }

    assert_redirected_to import_configuration_url(@import)
    assert_equal I18n.t("activerecord.errors.models.import.amount_type_values_exclusive"), flash[:alert]
  end

  test "a running import cannot be reconfigured" do
    @import.update_column(:status, "importing")
    TransactionImport.any_instance.expects(:generate_rows_from_csv).never

    patch import_configuration_url(@import), params: { import: { date_col_label: "Date" } }

    assert_redirected_to import_path(@import)
    assert_equal "This import can no longer be changed.", flash[:alert]
  end
end
