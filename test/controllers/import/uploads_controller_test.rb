require "test_helper"

class Import::UploadsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @import = imports(:transaction)
  end

  test "show" do
    get import_upload_url(@import)
    assert_response :success
  end

  test "uploads valid csv by copy and pasting" do
    patch import_upload_url(@import), params: {
      import: {
        raw_file_str: file_fixture("imports/valid.csv").read,
        col_sep: ","
      }
    }

    assert_redirected_to import_configuration_url(@import, template_hint: true)
    assert_equal "CSV uploaded successfully.", flash[:notice]
  end

  test "uploads valid csv by file" do
    patch import_upload_url(@import), params: {
      import: {
        csv_file: file_fixture_upload("imports/valid.csv"),
        col_sep: ","
      }
    }

    assert_redirected_to import_configuration_url(@import, template_hint: true)
    assert_equal "CSV uploaded successfully.", flash[:notice]
  end

  test "uploads a Windows-1251 csv file and stores it as UTF-8" do
    patch import_upload_url(@import), params: {
      import: {
        csv_file: file_fixture_upload("imports/windows1251.csv", "text/csv"),
        col_sep: ";"
      }
    }

    assert_redirected_to import_configuration_url(@import, template_hint: true)

    raw = @import.reload.raw_file_str
    assert_equal Encoding::UTF_8, raw.encoding
    assert raw.valid_encoding?
    assert_includes raw, "Сільпо, їжа на тиждень"
    assert_includes raw, "Ґудзик і нитки"
  end

  test "invalid csv cannot be uploaded" do
    patch import_upload_url(@import), params: {
      import: {
        csv_file: file_fixture_upload("imports/invalid.csv"),
        col_sep: ","
      }
    }

    assert_response :unprocessable_entity
    assert_equal "Must be valid CSV with headers and at least one row of data", flash[:alert]
  end

  test "uploading a new file drops rows and mappings from the previous one" do
    @import.update_column(:rows_count, @import.rows.count)
    @import.mappings.create!(type: "Import::CategoryMapping", key: "Old")

    patch import_upload_url(@import), params: {
      import: { raw_file_str: file_fixture("imports/valid.csv").read, col_sep: "," }
    }

    @import.reload
    assert_empty @import.rows
    assert_empty @import.mappings
    assert_equal 0, @import.rows_count
  end

  test "a running import cannot get a new file" do
    @import.update_column(:status, "importing")

    patch import_upload_url(@import), params: {
      import: { raw_file_str: file_fixture("imports/valid.csv").read, col_sep: "," }
    }

    assert_redirected_to import_path(@import)
    assert_nil @import.reload.raw_file_str
  end
end
