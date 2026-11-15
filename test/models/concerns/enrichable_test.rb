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

  test "a failed save enriches nothing and reports no change" do
    original_name = @enrichable.name

    assert_no_difference "DataEnrichment.count" do
      assert_equal false, @enrichable.enrich_attributes({ name: nil }, source: "plaid")
    end

    assert_equal original_name, @enrichable.name
    assert_equal original_name, @enrichable.reload.name
  end

  test "a new record keeps the enriched values when its first save fails" do
    account = families(:dylan_family).accounts.new

    account.enrich_attributes({ name: "Filled in" }, source: "plaid")

    assert account.new_record?
    assert_equal "Filled in", account.name
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

  test "a refused save rolls back the join rows a virtual setter wrote, inside a caller's transaction" do
    txn = transactions(:one)
    tag = tags(:three)
    tags_before = txn.tag_ids.sort
    refute_includes tags_before, tag.id

    txn.stubs(:save).returns(false)

    result = nil
    assert_no_difference -> { DataEnrichment.where(enrichable: txn).count } do
      Transaction.transaction do
        result = txn.enrich_attribute(:tag_ids, tags_before + [ tag.id ], source: "rule")
      end
    end

    assert_equal false, result
    assert_equal tags_before, Transaction.find(txn.id).tag_ids.sort
  end

  test "a refused tag_ids save leaves the instance reading the stored tags, and a retry writes" do
    txn = transactions(:one)
    tag = tags(:three)
    tags_before = txn.tag_ids.sort
    taggings_before = txn.taggings.map(&:tag_id).sort
    wanted = tags_before + [ tag.id ]

    txn.stubs(:save).returns(false)
    assert_no_difference "DataEnrichment.count" do
      assert_equal false, txn.enrich_attribute(:tag_ids, wanted, source: "rule")
    end

    assert_equal tags_before, txn.tag_ids.sort
    assert_equal taggings_before, txn.taggings.map(&:tag_id).sort

    txn.unstub(:save)
    assert_difference "DataEnrichment.count", 1 do
      assert txn.enrich_attribute(:tag_ids, wanted, source: "rule")
    end
    assert_equal wanted.sort, Transaction.find(txn.id).tag_ids.sort
  end

  test "a refused save keeps the previously accepted provenance value" do
    @enrichable.enrich_attribute(:name, "Accepted Name", source: "plaid")
    row = DataEnrichment.find_by!(enrichable: @enrichable, attribute_name: "name", source: "plaid")

    assert_equal false, @enrichable.enrich_attribute(:name, nil, source: "plaid")

    assert_equal "Accepted Name", row.reload.value
    assert_equal "Accepted Name", Account.find(@enrichable.id).name
  end
end
