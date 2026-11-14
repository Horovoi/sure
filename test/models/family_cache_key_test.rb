require "test_helper"

class FamilyCacheKeyTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  def version
    Family.find(@family.id).entries_cache_version
  end

  test "deleting an older entry changes the entries cache version" do
    entries = @family.entries.order(:updated_at).to_a
    skip "needs two entries" if entries.size < 2
    before = version

    entries.first.destroy!

    assert_not_equal before, version
  end

  test "changing the family currency changes both cache keys" do
    before_version = version
    before_key = @family.build_cache_key("x", invalidate_on_data_updates: true)

    @family.update!(currency: @family.currency == "USD" ? "EUR" : "USD")

    assert_not_equal before_version, version
    assert_not_equal before_key, Family.find(@family.id).build_cache_key("x", invalidate_on_data_updates: true)
  end

  test "disabling an account changes the entries cache version" do
    before = version
    @family.accounts.first.update!(status: "disabled")
    assert_not_equal before, version
  end

  test "the balance sheet key changes with the day, for today's exchange rate" do
    key_today = @family.build_cache_key("x")
    travel 1.day do
      assert_not_equal key_today, @family.build_cache_key("x")
    end
  end
end
