require "test_helper"

class InviteCodeTest < ActiveSupport::TestCase
  test "claim! destroys the invite token" do
    code = InviteCode.generate!

    assert_difference "InviteCode.count", -1 do
      InviteCode.claim! code
    end
  end

  test "claim! returns true if valid" do
    assert InviteCode.claim!(InviteCode.generate!)
  end

  test "claim! is falsy if invalid" do
    assert_not InviteCode.claim!("invalid")
  end

  test "generate! creates a new invite and returns its token" do
    assert_difference "InviteCode.count", +1 do
      assert_equal InviteCode.generate!, InviteCode.last.token
    end
  end

  test "claim! succeeds only once for the same code" do
    code = InviteCode.generate!

    assert InviteCode.claim!(code)
    assert_not InviteCode.claim!(code)
  end

  test "claim! is case-insensitive and rejects blank tokens" do
    assert InviteCode.claim!(InviteCode.generate!.upcase)
    assert_not InviteCode.claim!(nil)
    assert_not InviteCode.claim!("")
  end
end
