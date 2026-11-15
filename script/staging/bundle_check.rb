# Checks a backup bundle (Backup::Bundle) on the host for `bin/staging restore`.
# Standard library only: it runs with the host Ruby, outside the app.
#
#   ruby script/staging/bundle_check.rb verify <bundle-dir>
#     every file in the manifest exists with its size and sha256; prints the file names
#   ruby script/staging/bundle_check.rb compare <bundle-dir> <counts-file>
#     compares "table|count" lines (lib.sh table_counts) with the manifest row counts
require "json"
require "digest"

mode, dir, counts_file = ARGV
abort "usage: bundle_check.rb verify <dir> | compare <dir> <counts-file>" unless dir && %w[verify compare].include?(mode)

manifest_path = File.join(dir, "manifest.json")
abort "no manifest.json in #{dir}" unless File.file?(manifest_path)
manifest = JSON.parse(File.read(manifest_path))

case mode
when "verify"
  bad = manifest.fetch("files").filter_map do |file, info|
    path = File.join(dir, file)
    next "#{file}: missing" unless File.file?(path)
    next "#{file}: size #{File.size(path)}, manifest says #{info["size"]}" unless File.size(path) == info["size"]
    next "#{file}: sha256 does not match the manifest" unless Digest::SHA256.file(path).hexdigest == info["sha256"]
  end
  abort(bad.map { |line| "  #{line}" }.join("\n")) if bad.any?

  puts manifest.fetch("files").keys
when "compare"
  expected = manifest["table_counts"] or abort "the manifest has no row counts"
  actual = File.readlines(counts_file, chomp: true).to_h { |line| line.split("|", 2).then { |t, c| [ t, c.to_i ] } }

  differences = (expected.keys | actual.keys).sort.filter_map do |table|
    next if expected[table] == actual[table]

    "  #{table}: #{expected.fetch(table, "no table")} in the manifest, #{actual.fetch(table, "no table")} restored"
  end

  if differences.empty?
    puts "  row counts equal the manifest (#{expected.size} tables)"
  else
    puts "  row counts that differ from the manifest:"
    puts differences
  end
end
