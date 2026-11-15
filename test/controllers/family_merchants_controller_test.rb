require "test_helper"

class FamilyMerchantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @merchant = merchants(:netflix)
  end

  test "index" do
    get family_merchants_path
    assert_response :success
  end

  test "new" do
    get new_family_merchant_path
    assert_response :success
  end

  test "should create merchant" do
    assert_difference("FamilyMerchant.count") do
      post family_merchants_url, params: { family_merchant: { name: "new merchant", color: "#000000" } }
    end

    assert_redirected_to family_merchants_path
  end

  test "should update merchant" do
    patch family_merchant_url(@merchant), params: { family_merchant: { name: "new name", color: "#000000" } }
    assert_redirected_to family_merchants_path
  end

  test "should destroy merchant" do
    assert_difference("FamilyMerchant.count", -1) do
      delete family_merchant_url(@merchant)
    end

    assert_redirected_to family_merchants_path
  end

  # --- DS pickers: inline create through the JSON endpoint ---

  test "JSON create returns the new merchant with its option markup" do
    assert_difference "FamilyMerchant.count", +1 do
      post family_merchants_url(format: :json), params: { family_merchant: { name: "Corner Bakery" } }, as: :json
    end

    assert_response :created
    body = response.parsed_body
    assert_equal "Corner Bakery", body["name"]
    assert_includes body["html"], %(data-merchant-id="#{body["id"]}")
  end

  test "JSON create returns the validation errors" do
    post family_merchants_url(format: :json), params: { family_merchant: { name: "" } }, as: :json

    assert_response :unprocessable_entity
    assert response.parsed_body["errors"].any?
  end
end
