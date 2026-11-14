# Sends the same signed-in page requests to several running copies of the app, taking
# turns between them, and records how long each request takes. Plain Ruby, no Rails.
# Run by `bin/staging bench`.
require "net/http"
require "json"
require "digest"

TARGETS = { "old-a" => "web-old-a", "old-b" => "web-old-b", "new" => "web-new" }
SESSION = JSON.parse(File.read("/out/session.json"))
PATHS = SESSION.fetch("paths")
PORT = Integer(ENV.fetch("TARGET_PORT", "3333"))
ROUNDS = Integer(ENV.fetch("ROUNDS", "100"))
WARMUP = Integer(ENV.fetch("WARMUP", "15"))
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

class Client
  def initialize(host)
    @http = Net::HTTP.new(host, PORT)
    @http.read_timeout = 120
    @http.start
    @cookies = { "session_token" => SESSION.fetch("cookie") }
  end

  def get(path)
    req = Net::HTTP::Get.new(path)
    req["User-Agent"] = UA
    req["Host"] = "localhost"
    req["Accept"] = "text/html"
    req["Cookie"] = @cookies.map { |k, v| "#{k}=#{v}" }.join("; ")
    res = @http.request(req)
    (res.get_fields("set-cookie") || []).each do |c|
      k, v = c.split(";").first.split("=", 2)
      @cookies[k] = v
    end
    res
  end
end

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# Parts of a page that legitimately differ between two servers or two requests
def normalized(body)
  body.gsub(%r{/commit/[0-9a-f]{7,40}">[0-9a-f]{7}<}, "/commit/SHA\">SHA<")
      .gsub(%r{/assets/[\w./-]+-[0-9a-f]{8,}\.(js|css)}, "/assets/X")
      .gsub(%r{[A-Za-z0-9_+/=-]{40,}}, "TOKEN")
end

clients = TARGETS.transform_values { |host| Client.new(host) }

clients.each do |name, client|
  WARMUP.times { PATHS.each_value { |path| client.get(path).then { |r| raise "#{name} #{path}: HTTP #{r.code}" unless r.code == "200" } } }
end

digests = Hash.new { |h, k| h[k] = {} }
PATHS.each do |page, path|
  clients.each do |name, client|
    res = client.get(path)
    raise "#{name} #{path}: HTTP #{res.code}" unless res.code == "200"
    digests[page][name] = [ Digest::SHA256.hexdigest(normalized(res.body))[0, 12], res.body.bytesize ]
  end
end

times = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = [] } }
names = clients.keys
ROUNDS.times do |round|
  PATHS.each_with_index do |(page, path), i|
    names.rotate(round + i).each do |name|
      t = now
      res = clients[name].get(path)
      elapsed = (now - t) * 1000
      raise "#{name} #{path}: HTTP #{res.code}" unless res.code == "200"
      times[page][name] << elapsed
    end
  end
end

File.write("/out/http.json", JSON.generate(times: times, digests: digests, rounds: ROUNDS))
