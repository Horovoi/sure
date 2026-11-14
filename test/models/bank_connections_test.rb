require "test_helper"

class BankConnectionsTest < ActiveSupport::TestCase
  test "disabled by default" do
    with_env_overrides("BANK_CONNECTIONS_ENABLED" => nil) do
      assert_not BankConnections.enabled?
    end
  end

  test "enabled only by a true value" do
    { "true" => true, "1" => true, "false" => false, "0" => false, "" => false }.each do |value, expected|
      with_env_overrides("BANK_CONNECTIONS_ENABLED" => value) do
        assert_equal expected, BankConnections.enabled?, "BANK_CONNECTIONS_ENABLED=#{value.inspect}"
      end
    end
  end
end
