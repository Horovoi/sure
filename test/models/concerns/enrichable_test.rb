require "test_helper"

class EnrichableTest < ActiveSupport::TestCase
  setup do
    @enrichable = accounts(:depository)
  end

  test "can enrich multiple attributes" do
    assert_difference "DataEnrichment.count", 2 do
      @enrichable.enrich_attributes({ name: "Updated Checking", balance: 6_000 }, source: "plaid")
    end

    assert_equal "Updated Checking", @enrichable.name
    assert_equal 6_000, @enrichable.balance.to_d
  end

  test "can enrich a single attribute" do
    assert_difference "DataEnrichment.count", 1 do
      @enrichable.enrich_attribute(:name, "Single Update", source: "ai")
    end

    assert_equal "Single Update", @enrichable.name
  end

  test "can lock an attribute" do
    refute @enrichable.locked?(:name)

    @enrichable.lock_attr!(:name)
    assert @enrichable.locked?(:name)
  end

  test "can unlock an attribute" do
    @enrichable.lock_attr!(:name)
    assert @enrichable.locked?(:name)

    @enrichable.unlock_attr!(:name)
    refute @enrichable.locked?(:name)
  end

  test "can lock saved attributes" do
    @enrichable.name = "User Override"
    @enrichable.balance = 1_234
    @enrichable.save!

    @enrichable.lock_saved_attributes!

    assert @enrichable.locked?(:name)
    assert @enrichable.locked?(:balance)
  end

  test "does not enrich locked attributes" do
    original_name = @enrichable.name

    @enrichable.lock_attr!(:name)

    assert_no_difference "DataEnrichment.count" do
      @enrichable.enrich_attribute(:name, "Should Not Change", source: "plaid")
    end

    assert_equal original_name, @enrichable.reload.name
  end

  test "enrichable? reflects lock state" do
    assert @enrichable.enrichable?(:name)

    @enrichable.lock_attr!(:name)

    refute @enrichable.enrichable?(:name)
  end

  test "enrichable scope includes and excludes records based on lock state" do
    # Initially, the record should be enrichable for :name
    assert_includes Account.enrichable(:name), @enrichable

    @enrichable.lock_attr!(:name)

    refute_includes Account.enrichable(:name), @enrichable
  end

  test "locks record their source, and legacy timestamp locks count as user locks" do
    @enrichable.lock_attr!(:name, source: "ai")
    assert_equal "ai", @enrichable.lock_source(:name)
    refute @enrichable.user_locked?(:name)

    @enrichable.update!(locked_attributes: { "name" => Time.current.iso8601 })
    assert_equal "user", @enrichable.lock_source(:name)
    assert @enrichable.user_locked?(:name)
  end

  test "forced enrichment replaces an AI lock and releases it" do
    @enrichable.lock_attr!(:name, source: "ai")

    refute @enrichable.enrich_attribute(:name, "Not forced", source: "rule")
    assert @enrichable.enrich_attribute(:name, "Forced", source: "rule", force: true)

    @enrichable.reload
    assert_equal "Forced", @enrichable.name
    refute @enrichable.locked?(:name)
  end

  test "forced enrichment never replaces a user lock" do
    @enrichable.lock_attr!(:name)

    refute @enrichable.enrich_attribute(:name, "Forced", source: "rule", force: true)
    assert_not_equal "Forced", @enrichable.reload.name
  end

  test "forced enrichable scope excludes only user locks" do
    @enrichable.lock_attr!(:name, source: "ai")
    refute_includes Account.enrichable(:name), @enrichable
    assert_includes Account.enrichable(:name, force: true), @enrichable

    @enrichable.update!(locked_attributes: { "name" => Time.current.iso8601 })
    refute_includes Account.enrichable(:name, force: true), @enrichable
  end

  test "enrichment log is upserted per source and attribute" do
    @enrichable.enrich_attribute(:name, "First", source: "rule")

    assert_no_difference "DataEnrichment.count" do
      @enrichable.enrich_attribute(:name, "Second", source: "rule")
    end

    assert_equal "Second", DataEnrichment.find_by(enrichable: @enrichable, attribute_name: "name", source: "rule").value
  end
end
