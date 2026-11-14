require "test_helper"

class Import::ConfirmsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "shows if cleaned" do
    import = imports(:transaction)

    TransactionImport.any_instance.stubs(:cleaned?).returns(true)

    get import_confirm_path(import)
    assert_response :success
  end

  test "redirects if not cleaned" do
    import = imports(:transaction)

    TransactionImport.any_instance.stubs(:cleaned?).returns(false)

    get import_confirm_path(import)
    assert_redirected_to import_clean_path(import)
    assert_equal "You have invalid data, please edit until all errors are resolved", flash[:alert]
  end

  test "an import without mapping steps that is not cleaned goes to the clean step" do
    import = @user.family.imports.create!(type: "CategoryImport", raw_file_str: "name\nFood\n")

    get import_confirm_path(import)

    assert_redirected_to import_clean_path(import)
  end
end
