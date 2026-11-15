require "test_helper"

class VersionTest < ActiveSupport::TestCase
  setup { forget_commit_sha }
  teardown { forget_commit_sha }

  test "commit_sha is nil when git is not installed" do
    IO.stubs(:popen).raises(Errno::ENOENT)

    assert_nil Sure.commit_sha
    assert_equal "dev", Sure.build_tag
  end

  test "commit_sha is memoized" do
    IO.expects(:popen).once.returns("0123456789abcdef0123456789abcdef01234567\n")

    2.times { Sure.commit_sha }
  end

  test "build_tag outside production is dev plus the first 12 characters of HEAD" do
    sha = "0123456789abcdef0123456789abcdef01234567"
    Sure.stubs(:commit_sha).returns(sha)

    assert_equal "dev-0123456789ab", Sure.build_tag
  end

  test "build_tag in the test environment starts with dev" do
    assert_match(/\Adev/, Sure.build_tag)
  end

  test "build_tag in production is the first 12 characters of BUILD_COMMIT_SHA" do
    Rails.env.stubs(:production?).returns(true)

    with_env_overrides("BUILD_COMMIT_SHA" => "0123456789abcdef0123456789abcdef01234567") do
      assert_equal "0123456789abcdef0123456789abcdef01234567", Sure.commit_sha
      assert_equal "0123456789ab", Sure.build_tag
    end
  end

  test "build_tag in production is nil without BUILD_COMMIT_SHA" do
    Rails.env.stubs(:production?).returns(true)

    with_env_overrides("BUILD_COMMIT_SHA" => "") do
      assert_nil Sure.build_tag
    end
  end

  private
    def forget_commit_sha
      Sure.remove_instance_variable(:@commit_sha) if Sure.instance_variable_defined?(:@commit_sha)
    end
end
