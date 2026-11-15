require "test_helper"

class Backup::BundleTest < ActiveSupport::TestCase
  ENV_SECRET = "SECRET_KEY_BASE=plaintext-secret-that-must-never-be-copied".freeze

  setup do
    @tmp = Pathname(Dir.mktmpdir("backup-bundle-test"))
    @local = @tmp.join("backups")
    @offsite = @tmp.join("offsite")
    @env_file = @tmp.join("env.production")
    @env_file.write("#{ENV_SECRET}\n")
    @pipelines = []
    @commands = []
    stub_processes
  end

  teardown do
    FileUtils.rm_rf(@tmp)
  end

  test "create! writes every part and a manifest with sizes, sha256 and row counts" do
    dir = with_backup_env { Backup::Bundle.create!(kind: :manual) }

    assert_equal @local.join("bundles", "manual"), dir.dirname
    assert_match(/\A\d{8}T\d{6}Z_0123456789ab\z/, dir.basename.to_s)
    assert_equal %w[db.sql.gz icons.tar.gz manifest.json storage.tar.gz], dir.children.map { |path| path.basename.to_s }.sort

    manifest = JSON.parse(dir.join("manifest.json").read)
    assert_equal "manual", manifest["kind"]
    assert_equal "0123456789ab", manifest["tag"]
    assert_equal %w[db storage icons env], manifest["parts"]
    assert_equal ActiveRecord::Base.connection.select_value("SELECT max(version) FROM schema_migrations"), manifest["schema_version"]
    assert_equal "17.6", manifest["pg_dump_version"]
    assert_equal User.count, manifest["table_counts"]["users"]
    assert_equal Account.count, manifest["table_counts"]["accounts"]

    %w[db.sql.gz storage.tar.gz icons.tar.gz].each do |file|
      assert_equal dir.join(file).size, manifest["files"][file]["size"]
      assert_equal Digest::SHA256.file(dir.join(file)).hexdigest, manifest["files"][file]["sha256"]
    end
  end

  test "bundles go only under bundles/<kind>, never into the sidecar folders" do
    with_backup_env do
      Backup::Bundle.create!(kind: :daily)
      travel 1.second
      Backup::Bundle.create!(kind: :pre_reset, parts: %i[db storage])
    end

    assert_equal [ "bundles" ], @local.children.map { |path| path.basename.to_s }
    assert_equal %w[daily pre-reset], @local.join("bundles").children.map { |path| path.basename.to_s }.sort
    %w[daily weekly monthly last].each { |sidecar| assert_not @local.join(sidecar).exist? }
  end

  test "pre-reset bundles hold only the requested parts" do
    dir = with_backup_env { Backup::Bundle.create!(kind: :pre_reset, parts: %i[db storage]) }

    assert_equal %w[db.sql.gz manifest.json storage.tar.gz], dir.children.map { |path| path.basename.to_s }.sort
    assert_not JSON.parse(dir.join("manifest.json").read).key?("env")
  end

  test "the env file is skipped without a recipient and never copied in plain text" do
    dir = with_backup_env("BACKUP_AGE_RECIPIENT" => nil) { Backup::Bundle.create!(kind: :manual) }

    assert_equal "skipped", JSON.parse(dir.join("manifest.json").read)["env"]
    assert_not dir.join("env.production.age").exist?
    assert_no_command "age"
    assert_no_plaintext_env(dir)
    assert_no_plaintext_env(@offsite)
  end

  test "the env file is encrypted with age to the recipient, mode 600" do
    dir = with_backup_env("BACKUP_AGE_RECIPIENT" => "age1examplerecipient") { Backup::Bundle.create!(kind: :manual) }

    age = @commands.find { |argv| argv.first == "age" }
    assert_equal [ "age", "--encrypt", "--recipient", "age1examplerecipient", "--output", dir.join("env.production.age").to_s, @env_file.to_s ], age
    assert_equal "encrypted", JSON.parse(dir.join("manifest.json").read)["env"]
    assert_equal 0o600, dir.join("env.production.age").stat.mode & 0o777
    assert_no_plaintext_env(dir)
  end

  test "an empty dump raises and removes the partial folder" do
    @dump_content = ""

    error = assert_raises(Backup::Bundle::Error) do
      with_backup_env { Backup::Bundle.create!(kind: :manual) }
    end

    assert_match(/empty or incomplete/, error.message)
    assert_empty @local.join("bundles", "manual").children
    assert_not @offsite.join("bundles", "manual").exist?
  end

  test "a failing pg_dump raises and removes the partial folder" do
    @pipeline_success = false

    assert_raises(Backup::Bundle::Error) do
      with_backup_env { Backup::Bundle.create!(kind: :manual) }
    end

    assert_empty @local.join("bundles", "manual").children
  end

  test "pg_dump runs without a shell and gets the password only through the environment" do
    config = { host: "db", port: 5432, username: "sure_user", password: "s3cret-pass", database: "sure_production" }
    ActiveRecord::Base.stubs(:connection_db_config).returns(stub(configuration_hash: config))

    with_backup_env { Backup::Bundle.create!(kind: :manual) }

    pg_dump, gzip = @pipelines.first
    env, *argv = pg_dump
    assert_equal({ "PGPASSWORD" => "s3cret-pass" }, env)
    assert_equal [ "pg_dump", "--format=plain", "--no-password", "--host", "db", "--port", "5432",
                   "--username", "sure_user", "--dbname", "sure_production" ], argv
    assert argv.none? { |arg| arg.include?("s3cret-pass") }, "the password must not be in the argument list"
    assert_equal [ "gzip", "-c" ], gzip
  end

  test "the mirror holds an identical copy of every file" do
    dir = with_backup_env { Backup::Bundle.create!(kind: :manual) }
    copy = @offsite.join("bundles", "manual", dir.basename)

    assert copy.directory?
    dir.children.each do |file|
      assert_equal Digest::SHA256.file(file).hexdigest, Digest::SHA256.file(copy.join(file.basename)).hexdigest
    end
    assert_empty @offsite.join("bundles", "manual").children.select { |path| path.basename.to_s.end_with?(".partial") }
  end

  test "a mirror copy that does not match the manifest raises" do
    bundle = Backup::Bundle.new(:manual)
    def bundle.copy_tree(source, target)
      FileUtils.cp_r(source, target)
      target.join("db.sql.gz").write("corrupted on the way")
    end
    Backup::Bundle.stubs(:new).returns(bundle)

    error = assert_raises(Backup::Bundle::Error) do
      with_backup_env { Backup::Bundle.create!(kind: :manual) }
    end

    assert_match(/does not match the manifest/, error.message)
    assert_empty @offsite.join("bundles", "manual").children
  end

  test "prune keeps the newest bundles of the kind and leaves everything else alone" do
    manual = @local.join("bundles", "manual")
    old = (1..6).map { |day| fake_bundle(manual, "202001%02dT000000Z_old" % day) }
    unsealed = manual.join("20190101T000000Z_nomanifest").tap(&:mkpath)
    other_folder = manual.join("keep-me").tap(&:mkpath)
    stray_file = manual.join("notes.txt").tap { |path| path.write("mine") }
    sidecar_file = @local.join("daily", "sure-20200101.sql.gz").tap { |path| path.dirname.mkpath && path.write("sidecar") }
    other_kind = fake_bundle(@local.join("bundles", "daily"), "20190101T000000Z_old")

    dir = with_backup_env { Backup::Bundle.create!(kind: :manual) }

    kept = manual.children.select { |path| path.join("manifest.json").file? }.sort
    assert_equal 5, kept.size
    assert_includes kept, dir
    assert_equal old.last(4), (kept - [ dir ])
    [ unsealed, other_folder, stray_file, sidecar_file, other_kind ].each { |path| assert path.exist?, "#{path} should be kept" }
  end

  test "daily bundles keep 7 locally and 30 off-site" do
    assert_equal({ local: 7, offsite: 30 }, Backup::Bundle::RETENTION[:daily])
    assert_equal 10, Backup::Bundle::RETENTION.dig(:pre_deploy, :local)
    assert_equal 5, Backup::Bundle::RETENTION.dig(:pre_reset, :local)
    assert_equal 5, Backup::Bundle::RETENTION.dig(:manual, :local)

    daily_local = @local.join("bundles", "daily")
    daily_offsite = @offsite.join("bundles", "daily")
    (1..8).each { |day| fake_bundle(daily_local, "202001%02dT000000Z_old" % day) }
    (1..8).each { |day| fake_bundle(daily_offsite, "202001%02dT000000Z_old" % day) }

    with_backup_env { Backup::Bundle.create!(kind: :daily) }

    assert_equal 7, daily_local.children.size
    assert_equal 9, daily_offsite.children.size
  end

  test "seal! finishes a folder written by bin/deploy" do
    dir = @local.join("bundles", "pre-deploy", "20261115T040000Z_7d234ec14a1b").tap(&:mkpath)
    write_gzip(dir.join("db.sql.gz"), dump_text)
    write_gzip(dir.join("storage.tar.gz"), "storage tar")
    write_gzip(dir.join("icons.tar.gz"), "icons tar")

    with_backup_env("BACKUP_AGE_RECIPIENT" => "age1examplerecipient") do
      Backup::Bundle.seal!(dir.to_s, kind: "pre_deploy")
    end

    manifest = JSON.parse(dir.join("manifest.json").read)
    assert_equal "pre_deploy", manifest["kind"]
    assert_equal "7d234ec14a1b", manifest["tag"]
    assert_equal "encrypted", manifest["env"]
    assert_equal %w[db.sql.gz env.production.age icons.tar.gz storage.tar.gz], manifest["files"].keys
    assert_equal User.count, manifest["table_counts"]["users"]
    assert @offsite.join("bundles", "pre-deploy", dir.basename, "manifest.json").file?
    assert_empty @pipelines, "seal! does not dump the database again"
  end

  test "seal! rejects an invalid dump and leaves the folder for the owner" do
    dir = @local.join("bundles", "pre-deploy", "20261115T040000Z_7d234ec14a1b").tap(&:mkpath)
    dir.join("db.sql.gz").write("not gzip")
    write_gzip(dir.join("storage.tar.gz"), "storage tar")
    write_gzip(dir.join("icons.tar.gz"), "icons tar")

    assert_raises(Backup::Bundle::Error) do
      with_backup_env { Backup::Bundle.seal!(dir, kind: :pre_deploy) }
    end

    assert dir.join("db.sql.gz").file?
    assert_not dir.join("manifest.json").exist?
  end

  test "seal! refuses a folder outside bundles/<kind>" do
    dir = @local.join("daily", "20261115T040000Z_7d234ec14a1b").tap(&:mkpath)

    assert_raises(Backup::Bundle::Error) do
      with_backup_env { Backup::Bundle.seal!(dir, kind: :pre_deploy) }
    end
  end

  test "create! still runs on the staging copy" do
    dir = with_backup_env("STAGING_CLONE" => "1") { Backup::Bundle.create!(kind: :manual) }

    assert dir.join("manifest.json").file?
  end

  test "an unknown kind is rejected" do
    assert_raises(Backup::Bundle::Error) { Backup::Bundle.create!(kind: :hourly) }
  end

  private
    def with_backup_env(extra = {}, &block)
      env = {
        "BACKUP_ROOT" => @local.to_s,
        "OFFSITE_BACKUP_ROOT" => @offsite.to_s,
        "BACKUP_ENV_FILE" => @env_file.to_s,
        "BACKUP_AGE_RECIPIENT" => nil,
        "BUILD_COMMIT_SHA" => "0123456789abcdef0123456789abcdef01234567",
        "STAGING_CLONE" => nil
      }.merge(extra)
      with_env_overrides(env, &block)
    end

    def dump_text
      <<~SQL
        --
        -- PostgreSQL database dump
        --

        -- Dumped from database version 16.10
        -- Dumped by pg_dump version 17.6

        CREATE TABLE public.users (id uuid);

        --
        -- PostgreSQL database dump complete
        --
      SQL
    end

    def write_gzip(path, text)
      Zlib::GzipWriter.open(path.to_s) { |gz| gz.write(text) }
    end

    def fake_bundle(parent, name)
      parent.join(name).tap do |dir|
        dir.mkpath
        dir.join("manifest.json").write("{}")
      end
    end

    # Open3 stands in for pg_dump | gzip, tar and age: each writes its output file.
    # A failing pg_dump is simulated by setting @pipeline_success = false.
    def stub_processes
      test = self
      ok = stub(success?: true, exitstatus: 0)
      pg_dump_status = Object.new
      pg_dump_status.define_singleton_method(:success?) { test.instance_variable_get(:@pipeline_success) != false }
      pg_dump_status.define_singleton_method(:exitstatus) { success? ? 0 : 1 }

      Open3.stubs(:pipeline).with do |*commands|
        opts = commands.pop
        test.instance_variable_get(:@pipelines) << commands.map { |command| command.reject { |part| part.is_a?(Hash) && part.key?(:err) } }
        test.send(:write_gzip, Pathname(opts[:out]), test.instance_variable_get(:@dump_content) || test.send(:dump_text))
        true
      end.returns([ pg_dump_status, ok ])

      Open3.stubs(:capture3).with do |*argv|
        test.instance_variable_get(:@commands) << argv
        case argv.first
        when "tar" then test.send(:write_gzip, Pathname(argv[2]), "tar of #{argv[4]}")
        when "age" then File.binwrite(argv[argv.index("--output") + 1], "age-encryption.org/v1\nopaque")
        end
        true
      end.returns([ "", "", ok ])
    end

    def assert_no_command(name)
      assert @commands.none? { |argv| argv.first == name }, "#{name} should not run"
    end

    def assert_no_plaintext_env(root)
      return unless root.exist?

      Dir.glob(root.join("**", "*")).select { |path| File.file?(path) }.each do |path|
        assert_not_includes File.binread(path), ENV_SECRET, "#{path} holds the env file in plain text"
      end
    end
end
