namespace :rules do
  desc "Apply all active rules for a family"
  task :apply_all, [ :family_id ] => :environment do |_t, args|
    family_id = args[:family_id]

    if family_id.blank?
      puts "Usage: bin/rails rules:apply_all[family_id]"
      exit 1
    end

    family = Family.find(family_id)
    rules = family.rules.where(active: true)

    if rules.empty?
      puts "No active rules found for family #{family_id}"
      exit 0
    end

    puts "Applying #{rules.count} rules for family #{family_id}..."

    # One top-to-bottom pass, like "Apply all" in the UI. Called directly rather than
    # through a job, so a busy family lock fails here instead of being retried in the
    # background while the task reports success.
    runner = Rule::Runner.new(family, rules: rules, execution_type: "manual", ignore_attribute_locks: true)

    begin
      rule_runs = runner.run
    rescue Rule::Runner::LockBusy => e
      puts "failed: #{e.message}. Try again once the current sync has finished."
      exit 1
    end

    rule_runs.each do |rule_run|
      line = "  Rule '#{rule_run.rule_name || rule_run.rule_id}': #{rule_run.status}"
      line += " (#{rule_run.error_message})" if rule_run.error_message.present?
      puts line
    end

    puts "Finished applying all rules"
    exit 1 if runner.errors.any?
  end
end
