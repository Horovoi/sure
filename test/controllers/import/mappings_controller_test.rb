require "test_helper"

class Import::MappingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)

    @import = imports(:transaction)
  end

  test "updates mapping" do
    mapping = import_mappings(:one)
    new_category = categories(:income)

    patch import_mapping_path(@import, mapping), params: {
      import_mapping: {
        mappable_type: "Category",
        mappable_id: new_category.id,
        key: "Food"
      }
    }

    mapping.reload

    assert_equal new_category, mapping.mappable
    assert_equal "Food", mapping.key

    assert_redirected_to import_confirm_path(@import)
  end

  test "the mappable class comes from the mapping, not the request" do
    mapping = import_mappings(:one)

    patch import_mapping_path(@import, mapping), params: {
      import_mapping: { mappable_type: "User", mappable_id: users(:family_admin).id, key: "Food" }
    }

    assert_nil mapping.reload.mappable
  end

  test "a published import's mappings cannot change" do
    mapping = import_mappings(:one)
    @import.update_column(:status, "complete")

    patch import_mapping_path(@import, mapping), params: {
      import_mapping: { mappable_type: "Category", mappable_id: categories(:income).id, key: "Food" }
    }

    assert_redirected_to import_path(@import)
    assert_not_equal categories(:income), mapping.reload.mappable
  end
end
