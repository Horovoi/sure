require "test_helper"

class BankConnectionsTest < ActiveSupport::TestCase
  BUILT_IN = %w[plaid lunchflow enable_banking coinstats coinbase].freeze

  test "disabled by default" do
    with_env_overrides("BANK_CONNECTIONS_ENABLED" => nil) do
      assert_not BankConnections.enabled?
      assert_empty BankConnections.enabled_keys
      assert_empty BankConnections.enabled_providers
    end
  end

  test "false values turn every provider off, true values turn every registered one on" do
    { "true" => true, "1" => true, "yes" => true, "TRUE" => true, "false" => false, "0" => false, "no" => false, "" => false }.each do |value, expected|
      with_env_overrides("BANK_CONNECTIONS_ENABLED" => value) do
        assert_equal expected, BankConnections.enabled?, "BANK_CONNECTIONS_ENABLED=#{value.inspect}"
        expected_keys = expected ? BankConnections.providers.map(&:key).to_set : Set.new
        assert_equal expected_keys, BankConnections.enabled_keys, "BANK_CONNECTIONS_ENABLED=#{value.inspect}"
      end
    end
  end

  test "a list turns on only the named providers" do
    with_env_overrides("BANK_CONNECTIONS_ENABLED" => "lunchflow") do
      assert BankConnections.enabled?
      assert BankConnections.enabled?(:lunchflow)
      assert BankConnections.enabled?("lunchflow")
      assert_not BankConnections.enabled?(:plaid)
      assert_equal [ "lunchflow" ], BankConnections.enabled_providers.map(&:key)
      assert_equal [ "LunchflowAccount" ], BankConnections.enabled_account_class_names
    end

    with_env_overrides("BANK_CONNECTIONS_ENABLED" => " coinstats, plaid  coinbase") do
      assert_equal %w[plaid coinstats coinbase], BankConnections.enabled_providers.map(&:key)
    end
  end

  test "unknown keys are ignored with a warning" do
    Rails.logger.expects(:warn).with(regexp_matches(/unknown bank connection keys ignored: junk/)).at_least_once

    with_env_overrides("BANK_CONNECTIONS_ENABLED" => "junk,plaid") do
      assert_equal Set.new([ "plaid" ]), BankConnections.enabled_keys
    end
  end

  test "only junk enables nothing" do
    with_env_overrides("BANK_CONNECTIONS_ENABLED" => "junk") do
      assert_not BankConnections.enabled?
    end
  end

  test "built-in providers are registered in sync order" do
    assert_equal BUILT_IN, BankConnections.providers.map(&:key).first(BUILT_IN.size)
    plaid = BankConnections.provider(:plaid)
    assert_equal :plaid_items, plaid.association
    assert_equal "PlaidItem", plaid.item_class_name
    assert_equal %w[plaid plaid_eu], plaid.config_keys
    assert BankConnections.provider(:coinstats).hourly?
    assert_equal "settings/providers/lunchflow_panel", BankConnections.provider(:lunchflow).settings_partial
    assert_nil BankConnections.provider(:nope)
    assert_nil BankConnections.provider(nil)
  end

  test "item associations match the provider item has_many reflections of Family" do
    reflected = Family.reflect_on_all_associations(:has_many).map(&:name).select { |name| name.to_s.end_with?("_items") }

    assert_equal reflected.sort, BankConnections.item_associations.sort
  end

  test "item associations of the enabled providers only" do
    enable_bank_connections(:coinbase, :plaid)

    assert_equal %i[plaid_items coinbase_items], BankConnections.item_associations(enabled_only: true)
    assert_equal BankConnections.providers.size, BankConnections.item_associations.size
  end

  test "looks providers up by account and item class" do
    assert_equal "lunchflow", BankConnections.provider_for_account_class("LunchflowAccount").key
    assert_equal "coinstats", BankConnections.provider_for_item_class("CoinstatsItem").key
    assert_nil BankConnections.provider_for_account_class("Nope")
  end

  test "a provider can register itself, and replaces an earlier registration" do
    registry = BankConnections.send(:registry)
    before = registry.dup

    BankConnections.register(:testbank, association: :testbank_items, item_class_name: "TestbankItem",
      account_class_name: "TestbankAccount", label: "Testbank", hourly: true, balance_includes_pending: true,
      generic_listing: true)
    provider = BankConnections.register(:testbank, association: :testbank_items, item_class_name: "TestbankItem",
      account_class_name: "TestbankAccount", label: "Testbank 2")

    assert_equal "Testbank 2", BankConnections.provider(:testbank).label
    assert_equal provider, BankConnections.providers.last
    assert_not provider.hourly?
    assert_equal 1, BankConnections.providers.count { |p| p.key == "testbank" }

    with_env_overrides("BANK_CONNECTIONS_ENABLED" => "testbank") do
      assert BankConnections.enabled?(:testbank)
      assert_equal [ "TestbankAccount" ], BankConnections.enabled_account_class_names
    end
  ensure
    registry.replace(before)
  end

  test "the test helper turns on all or some providers" do
    enable_bank_connections
    assert_equal BankConnections.providers.map(&:key).to_set, BankConnections.enabled_keys

    enable_bank_connections(:plaid)
    assert BankConnections.enabled?(:plaid)
    assert_not BankConnections.enabled?(:lunchflow)
  end
end
