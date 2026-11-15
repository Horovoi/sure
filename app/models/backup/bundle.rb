require "open3"

# A restorable copy of this install in one folder: the database, uploaded files,
# cached icons, the encrypted .env.production and a manifest that describes them.
#
#   BACKUP_ROOT/bundles/<kind>/<UTC stamp>_<tag>/
#     db.sql.gz           plain SQL dump (gunzip -c db.sql.gz | psql)
#     storage.tar.gz      /rails/storage (Active Storage files)
#     icons.tar.gz        /rails/public/icons (cached subscription icons)
#     env.production.age  .env.production, encrypted to BACKUP_AGE_RECIPIENT
#     manifest.json       kind, tag, schema version, row counts, size and sha256 per file
#
# Every finished bundle is copied to OFFSITE_BACKUP_ROOT/bundles/<kind>/ and checked
# there, then both places are pruned to the retention of its kind.
#
# BACKUP_ROOT also holds the folders of the daily database sidecar (daily, weekly,
# monthly, last). The sidecar prunes those itself; bundles never write or delete there.
#
# Nothing here looks at STAGING_CLONE: on the staging copy the worker mounts
# backups/staging, so manual and pre-reset bundles land there. Only the scheduled
# FullBackupJob stays off on staging.
class Backup::Bundle
  class Error < StandardError; end

  # Local and off-site copies kept per kind. Older bundles are deleted.
  RETENTION = {
    daily: { local: 7, offsite: 30 },
    pre_deploy: { local: 10, offsite: 10 },
    pre_reset: { local: 5, offsite: 5 },
    manual: { local: 5, offsite: 5 }
  }.freeze

  PARTS = %i[db storage icons env].freeze
  DEFAULT_PARTS = PARTS

  DB_FILE = "db.sql.gz".freeze
  STORAGE_FILE = "storage.tar.gz".freeze
  ICONS_FILE = "icons.tar.gz".freeze
  ENV_FILE = "env.production.age".freeze
  MANIFEST_FILE = "manifest.json".freeze

  # The files bin/deploy writes before it calls seal!
  SEALABLE_FILES = [ DB_FILE, STORAGE_FILE, ICONS_FILE ].freeze

  # <UTC stamp>_<tag>, e.g. 20261115T040000Z_7d234ec14a1b. Prune deletes only folders
  # with this name (and a manifest), so nothing else under the root is ever removed.
  STAMP_FORMAT = "%Y%m%dT%H%M%SZ".freeze
  NAME_PATTERN = /\A\d{8}T\d{6}Z_[A-Za-z0-9.\-]+\z/

  # Last line of every complete plain-format pg_dump
  DUMP_COMPLETE_MARKER = "-- PostgreSQL database dump complete".freeze

  MANIFEST_FORMAT = 1

  class << self
    # Writes a new bundle and returns its folder. Raises Error, and removes the
    # partial folder, when any step fails.
    def create!(kind:, parts: DEFAULT_PARTS)
      new(kind).create!(parts.map(&:to_sym))
    end

    # Finishes a folder that already holds db.sql.gz, storage.tar.gz and icons.tar.gz
    # (written by bin/deploy): checks them, adds the encrypted env file and the
    # manifest, mirrors and prunes. A failure leaves the folder as it was.
    def seal!(dir, kind:)
      new(kind).seal!(Pathname(dir))
    end

    def local_root
      root_from_env("BACKUP_ROOT", "tmp/backups")
    end

    def offsite_root
      root_from_env("OFFSITE_BACKUP_ROOT", "tmp/backups/offsite")
    end

    def kind_dir(root, kind)
      root.join("bundles", kind.to_s.dasherize)
    end

    private
      # Inside the container the compose file sets the roots. Development and test
      # fall back to folders under tmp/; production without them is a setup error.
      def root_from_env(key, default)
        value = ENV[key].presence
        return Pathname(value) if value
        raise Error, "#{key} is not set" if Rails.env.production?

        Rails.root.join(default)
      end
  end

  attr_reader :kind

  def initialize(kind)
    @kind = kind.to_sym
    raise Error, "unknown backup kind: #{kind.inspect} (one of #{RETENTION.keys.join(", ")})" unless RETENTION.key?(@kind)
  end

  def create!(parts)
    unknown = parts - PARTS
    raise Error, "unknown backup parts: #{unknown.join(", ")}" if unknown.any?
    raise Error, "a bundle needs at least one part" if parts.empty?

    dir = new_bundle_dir
    begin
      table_counts = nil
      if parts.include?(:db)
        with_consistent_snapshot do |snapshot|
          table_counts = read_table_counts
          dump_database(dir.join(DB_FILE), snapshot: snapshot)
        end
        verify_dump!(dir.join(DB_FILE))
      end

      archive(storage_source, dir.join(STORAGE_FILE)) if parts.include?(:storage)
      archive(icons_source, dir.join(ICONS_FILE)) if parts.include?(:icons)
      ([ STORAGE_FILE, ICONS_FILE ] & present_files(dir)).each { |file| verify_gzip!(dir.join(file)) }

      finish(dir, parts: parts, table_counts: table_counts, include_env: parts.include?(:env))
    rescue StandardError => e
      FileUtils.rm_rf(dir)
      raise e.is_a?(Error) ? e : Error.new("#{kind} backup failed: #{e.message}")
    end

    dir
  end

  def seal!(dir)
    raise Error, "#{dir} is not a bundle folder under #{self.class.kind_dir(self.class.local_root, kind)}" unless sealable_location?(dir)
    raise Error, "#{dir} is already sealed" if dir.join(MANIFEST_FILE).exist?

    missing = SEALABLE_FILES.reject { |file| dir.join(file).file? }
    raise Error, "#{dir} is missing #{missing.join(", ")}" if missing.any?

    verify_dump!(dir.join(DB_FILE))
    verify_gzip!(dir.join(STORAGE_FILE))
    verify_gzip!(dir.join(ICONS_FILE))

    finish(dir, parts: PARTS, table_counts: read_table_counts, include_env: true)
    dir
  rescue Error
    raise
  rescue StandardError => e
    raise Error, "sealing #{dir} failed: #{e.message}"
  end

  private
    # Shared last steps of create! and seal!
    def finish(dir, parts:, table_counts:, include_env:)
      env_status = include_env ? encrypt_env(dir.join(ENV_FILE)) : nil
      write_manifest(dir, parts: parts, table_counts: table_counts, env_status: env_status)
      mirror(dir)
      prune(self.class.local_root, RETENTION.dig(kind, :local))
      prune(self.class.offsite_root, RETENTION.dig(kind, :offsite))
    end

    def new_bundle_dir
      parent = self.class.kind_dir(self.class.local_root, kind)
      FileUtils.mkdir_p(parent)
      dir = parent.join("#{Time.now.utc.strftime(STAMP_FORMAT)}_#{tag}")
      Dir.mkdir(dir)
      dir
    rescue Errno::EEXIST
      raise Error, "#{dir} already exists; try again in a second"
    end

    def sealable_location?(dir)
      dir.directory? &&
        dir.basename.to_s.match?(NAME_PATTERN) &&
        dir.dirname.expand_path == self.class.kind_dir(self.class.local_root, kind).expand_path
    end

    # The image's commit (the first 12 characters, like bin/deploy's image tags)
    def tag
      sha = ENV["BUILD_COMMIT_SHA"].to_s.gsub(/[^A-Za-z0-9.\-]/, "")
      sha.present? ? sha.first(12) : "dev"
    end

    def present_files(dir)
      dir.children.select(&:file?).map { |path| path.basename.to_s }
    end

    # -- Database ---------------------------------------------------------------

    def connection
      ActiveRecord::Base.connection
    end

    # Dump and row counts share one snapshot, so the counts describe exactly the rows
    # in the dump. Inside an open transaction (tests) the isolation level cannot be
    # set, so the counts are read without a shared snapshot.
    def with_consistent_snapshot
      if connection.transaction_open?
        yield nil
      else
        connection.transaction(isolation: :repeatable_read) do
          yield connection.select_value("SELECT pg_export_snapshot()")
        end
      end
    end

    def read_table_counts
      tables = connection.select_values(<<~SQL)
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
        ORDER BY table_name
      SQL
      tables.index_with do |table|
        connection.select_value("SELECT count(*) FROM #{connection.quote_table_name("public.#{table}")}").to_i
      end
    end

    def schema_version
      connection.select_value("SELECT max(version) FROM schema_migrations")
    end

    # pg_dump | gzip -c > path, without a shell. The password travels only in the
    # child's PGPASSWORD, never in the argument list.
    def dump_database(path, snapshot:)
      db = ActiveRecord::Base.connection_db_config.configuration_hash
      argv = [ "pg_dump", "--format=plain", "--no-password" ]
      argv += [ "--host", db[:host].to_s ] if db[:host].present?
      argv += [ "--port", db[:port].to_s ] if db[:port].present?
      user = db[:username].presence || db[:user].presence
      argv += [ "--username", user.to_s ] if user
      argv << "--snapshot=#{snapshot}" if snapshot
      argv += [ "--dbname", db[:database].to_s ]

      env = { "PGPASSWORD" => db[:password].to_s }
      run_pipeline([ env, *argv ], [ "gzip", "-c" ], out: path, what: "pg_dump")
    end

    # A complete, readable dump: not empty, a valid gzip stream, and ending with the
    # line pg_dump writes last.
    def verify_dump!(path)
      tail = verify_gzip!(path)
      raise Error, "#{path.basename} is empty or incomplete (no end-of-dump marker)" unless tail.include?(DUMP_COMPLETE_MARKER)
    end

    # The gzip -t check: reads the whole stream, which also verifies its CRC. Returns
    # the last bytes of the content for verify_dump!.
    def verify_gzip!(path)
      raise Error, "#{path.basename} is missing or empty" unless path.file? && path.size.positive?

      tail = +""
      Zlib::GzipReader.open(path) do |gz|
        while (chunk = gz.read(1.megabyte))
          tail = (tail + chunk).last(4.kilobytes)
        end
      end
      tail
    rescue Zlib::Error => e
      raise Error, "#{path.basename} is not a valid gzip file: #{e.message}"
    end

    # The first lines of a plain dump name the server and pg_dump versions
    def dump_versions(path)
      head = Zlib::GzipReader.open(path) { |gz| gz.read(4.kilobytes).to_s }
      {
        pg_dump_version: head[/^-- Dumped by pg_dump version (.+)$/, 1],
        server_version: head[/^-- Dumped from database version (.+)$/, 1]
      }
    rescue Zlib::Error
      {}
    end

    # -- Files ------------------------------------------------------------------

    def storage_source
      Pathname(ENV.fetch("BACKUP_STORAGE_DIR") { Rails.root.join("storage").to_s })
    end

    def icons_source
      Pathname(ENV.fetch("BACKUP_ICONS_DIR") { Rails.root.join("public", "icons").to_s })
    end

    # tar -czf out -C source . (an empty archive when the folder does not exist yet)
    def archive(source, out)
      if source.directory?
        run!("tar", "-czf", out.to_s, "-C", source.to_s, ".", what: "tar #{source}")
      else
        Dir.mktmpdir { |empty| run!("tar", "-czf", out.to_s, "-C", empty, ".", what: "tar (empty #{source})") }
      end
    end

    # age -r <recipient> -o out <env file>. The env file is read by age directly and
    # never copied in plain text. Returns the manifest's env status.
    def encrypt_env(out)
      recipient = ENV["BACKUP_AGE_RECIPIENT"].presence
      return "skipped" unless recipient

      source = ENV["BACKUP_ENV_FILE"].presence
      raise Error, "BACKUP_AGE_RECIPIENT is set but BACKUP_ENV_FILE is not" unless source
      raise Error, "env file #{source} is not readable" unless File.readable?(source)

      run!("age", "--encrypt", "--recipient", recipient, "--output", out.to_s, source, what: "age")
      raise Error, "age wrote no #{out.basename}" unless out.file? && out.size.positive?

      File.chmod(0o600, out)
      "encrypted"
    end

    # -- Manifest -----------------------------------------------------------------

    def write_manifest(dir, parts:, table_counts:, env_status:)
      files = present_files(dir).reject { |file| file == MANIFEST_FILE }.sort.index_with do |file|
        path = dir.join(file)
        { size: path.size, sha256: Digest::SHA256.file(path).hexdigest }
      end

      manifest = {
        format: MANIFEST_FORMAT,
        kind: kind.to_s,
        tag: dir.basename.to_s.split("_", 2).last,
        build_commit_sha: ENV["BUILD_COMMIT_SHA"].presence,
        created_at: Time.now.utc.iso8601,
        schema_version: schema_version,
        parts: parts.map(&:to_s),
        env: env_status,
        table_counts: table_counts,
        files: files
      }
      manifest.merge!(dump_versions(dir.join(DB_FILE))) if files.key?(DB_FILE)

      dir.join(MANIFEST_FILE).write(JSON.pretty_generate(manifest.compact) + "\n")
    end

    def read_manifest(dir)
      JSON.parse(dir.join(MANIFEST_FILE).read)
    end

    # -- Mirror and prune ---------------------------------------------------------

    # Copies the bundle next to the off-site bundles of its kind under a temporary
    # name, checks every file against the manifest, then gives it its real name.
    def mirror(dir)
      parent = self.class.kind_dir(self.class.offsite_root, kind)
      FileUtils.mkdir_p(parent)
      target = parent.join(dir.basename)
      partial = parent.join(".#{dir.basename}.partial")
      raise Error, "off-site copy #{target} already exists" if target.exist?

      FileUtils.rm_rf(partial)
      copy_tree(dir, partial)

      read_manifest(dir).fetch("files").each do |file, info|
        copied = partial.join(file)
        actual = copied.file? ? Digest::SHA256.file(copied).hexdigest : nil
        next if actual == info.fetch("sha256")

        FileUtils.rm_rf(partial)
        raise Error, "off-site copy of #{file} does not match the manifest (sha256 #{actual.inspect})"
      end

      File.rename(partial, target)
    end

    def copy_tree(source, target)
      FileUtils.cp_r(source, target, preserve: true)
    end

    # Keeps the newest `keep` bundles of this kind under root. Only folders named
    # <stamp>_<tag> that hold a manifest count; anything else is left alone.
    def prune(root, keep)
      parent = self.class.kind_dir(root, kind)
      return unless parent.directory?

      bundles = parent.children.select do |path|
        path.directory? && path.basename.to_s.match?(NAME_PATTERN) && path.join(MANIFEST_FILE).file?
      end
      bundles.sort_by { |path| path.basename.to_s }.reverse.drop(keep).each do |old|
        FileUtils.rm_r(old, secure: true)
        Rails.logger.info("[Backup::Bundle] pruned #{old}")
      end
    end

    # -- Processes ------------------------------------------------------------------

    def run!(*argv, what:)
      _out, err, process = Open3.capture3(*argv)
      raise Error, "#{what} failed (exit #{process.exitstatus}): #{err.strip.truncate(500)}" unless process.success?
    end

    def run_pipeline(*commands, out:, what:)
      Tempfile.create("backup-err") do |err|
        with_err = commands.map { |command| [ *command, { err: [ err.path, "a" ] } ] }
        statuses = Open3.pipeline(*with_err, out: out.to_s)
        failed = statuses.reject(&:success?)
        next if failed.empty?

        message = File.read(err.path).strip.truncate(500)
        raise Error, "#{what} failed (exit #{failed.map(&:exitstatus).join(", ")}): #{message}"
      end
    end
end
