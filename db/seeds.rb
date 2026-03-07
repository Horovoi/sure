# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

if Rails.env.production? && !ENV["ALLOW_SEEDS"]
  abort <<~MSG
    \e[31m[BLOCKED] Seeds cannot run in production!\e[0m

    This safeguard prevents accidental data loss from db:setup or db:seed.
    If you genuinely need to run seeds in production, set:

      ALLOW_SEEDS=1 bin/rails db:seed
  MSG
end

puts 'Run the following command to create demo data: `rake demo_data:default`' if Rails.env.development?

Dir[Rails.root.join('db', 'seeds', '*.rb')].sort.each do |file|
  puts "Loading seed file: #{File.basename(file)}"
  require file
end
