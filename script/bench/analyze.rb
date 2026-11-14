# Summarises a benchmark run: per page, the median time per container and the paired
# difference against the first old container, with a bootstrap 95% interval.
# The "old-b vs old-a" column compares two containers of the same version: differences
# between old and new that are no larger than that are noise.
require "json"

def median(xs) = xs.sort.then { |s| s.size.odd? ? s[s.size / 2] : (s[s.size / 2 - 1] + s[s.size / 2]) / 2.0 }

def interval(diffs, rng)
  boots = Array.new(4000) { median(Array.new(diffs.size) { diffs[rng.rand(diffs.size)] }) }.sort
  [ boots[100], boots[3899] ]
end

rng = Random.new(42)
runs = ARGV.map { |f| JSON.parse(File.read(f)) }
pages = runs.first["times"].keys
times = pages.to_h { |p| [ p, %w[old-a old-b new].to_h { |t| [ t, runs.flat_map { |r| r["times"][p][t] } ] } ] }
n = times.values.first["new"].size

puts "#{n} timed requests per page per container, median milliseconds\n\n"
puts format("%-22s %8s %8s %8s   %-26s %-26s", "page", "old-a", "old-b", "new", "old-b vs old-a (same image)", "new vs old-a")
row = lambda do |label, t|
  same = t["old-b"].zip(t["old-a"]).map { |b, a| b - a }
  diff = t["new"].zip(t["old-a"]).map { |b, a| b - a }
  cs, cd = interval(same, rng), interval(diff, rng)
  puts format("%-22s %8.1f %8.1f %8.1f   %+6.2f [%+5.2f, %+5.2f]      %+6.2f [%+5.2f, %+5.2f]",
              label, median(t["old-a"]), median(t["old-b"]), median(t["new"]), median(same), *cs, median(diff), *cd)
end
times.each { |page, t| row.call(page, t) }
total = %w[old-a old-b new].to_h { |t| [ t, (0...n).map { |i| pages.sum { |p| times[p][t][i] } } ] }
puts
row.call("all pages (sum)", total)

identical = runs.all? { |r| r["digests"].all? { |_, d| d.values.map(&:first).uniq.size == 1 } }
puts "\npages identical across old and new: #{identical ? 'yes' : 'NO'}"
unless identical
  runs.each { |r| r["digests"].each { |p, d| puts "  #{p} differs (bytes: #{d.transform_values(&:last)})" if d.values.map(&:first).uniq.size > 1 } }
end
