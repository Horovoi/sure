namespace :backup do
  desc "Write a full backup bundle (database, files, icons, encrypted env). KIND: manual (default), daily, pre_deploy, pre_reset"
  task :create, [ :kind ] => :environment do |_task, args|
    kind = args[:kind].presence || "manual"
    dir = Backup::Bundle.create!(kind: kind)
    puts "Backup bundle written: #{dir}"
  rescue Backup::Bundle::Error => e
    abort "Backup failed: #{e.message}"
  end

  desc "Finish a bundle folder written by bin/deploy: add the encrypted env and the manifest, mirror off-site, prune"
  task :seal, [ :dir, :kind ] => :environment do |_task, args|
    abort "usage: bin/rails 'backup:seal[<dir>,<kind>]'" if args[:dir].blank? || args[:kind].blank?

    dir = Backup::Bundle.seal!(args[:dir], kind: args[:kind])
    puts "Backup bundle sealed: #{dir}"
  rescue Backup::Bundle::Error => e
    abort "Sealing the backup failed: #{e.message}"
  end
end
