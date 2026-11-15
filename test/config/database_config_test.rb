require "test_helper"

class DatabaseConfigTest < ActiveSupport::TestCase
  # With `user:` the PostgreSQL adapter passed the key straight to libpq, which
  # understands it, so Rails connected and nothing looked wrong. But
  # configuration_hash had no :username, so code that reads it (Backup::Bundle's
  # pg_dump --username) got nil and libpq fell back to the OS user. The file is
  # read directly because a DATABASE_URL would hide the key in the resolved config.
  test "database.yml uses the username key Rails documents, not user" do
    default_block = File.read(Rails.root.join("config/database.yml"))[/^default: &default\n(?:[ \t]+.*\n|\n)*/]

    assert_match(/^\s+username:/, default_block)
    refute_match(/^\s+user:/, default_block, "`user:` is not a Rails config key; use `username:`")
  end

  test "the resolved connection config carries username and no user key" do
    skip "DATABASE_URL overrides database.yml" if ENV["DATABASE_URL"].present?

    config = ActiveRecord::Base.connection_db_config.configuration_hash

    assert config.key?(:username), "the resolved config carries no :username"
    refute config.key?(:user), "`user:` leaked into the resolved config"
  end
end
