require "test_helper"

class SubscriptionServiceTest < ActiveSupport::TestCase
  test "validates presence of required fields" do
    service = SubscriptionService.new
    assert_not service.valid?
    assert_includes service.errors[:name], "can't be blank"
    assert_includes service.errors[:slug], "can't be blank"
    assert_includes service.errors[:domain], "can't be blank"
  end

  test "validates uniqueness of slug" do
    existing = subscription_services(:netflix)
    duplicate = SubscriptionService.new(
      name: "Another Netflix",
      slug: existing.slug,
      domain: "other.com"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:slug], "has already been taken"
  end

  test "validates category inclusion" do
    service = SubscriptionService.new(
      name: "Test",
      slug: "test",
      domain: "test.com",
      category: "invalid"
    )
    assert_not service.valid?
    assert_includes service.errors[:category], "is not included in the list"
  end

  test "allows blank category" do
    service = SubscriptionService.new(
      name: "Test",
      slug: "test",
      domain: "test.com",
      category: nil
    )
    assert service.valid?
  end

  test "search scope filters by name" do
    results = SubscriptionService.search("net")
    assert_includes results, subscription_services(:netflix)
    assert_not_includes results, subscription_services(:spotify)
  end

  test "by_category scope filters by category" do
    results = SubscriptionService.by_category("streaming")
    assert_includes results, subscription_services(:netflix)
    assert_not_includes results, subscription_services(:spotify)
  end

  test "logo_url returns brandfetch URL when client_id is configured" do
    Setting.stubs(:brand_fetch_client_id).returns("test_client_id")
    Setting.stubs(:brand_fetch_logo_size).returns(128)

    service = subscription_services(:netflix)
    expected_url = "https://cdn.brandfetch.io/netflix.com/icon/fallback/lettermark/w/128/h/128?c=test_client_id"

    assert_equal expected_url, service.logo_url
  end

  test "logo_url returns nil when client_id is not configured" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)

    service = subscription_services(:netflix)
    assert_nil service.logo_url
  end
end
