# Run using bin/ci: every check a change must pass before it is merged or deployed.
# There is no CI server; this runs on the machine that also builds and runs production.

CI.run do
  step "Autoloading", "bin/rails zeitwerk:check"

  step "Style: Ruby", "bin/rubocop"
  step "Style: ERB", "bundle exec erb_lint --lint-all"

  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"

  step "Tests: Rails", "bin/rails test"
  step "Tests: System", "bin/rails test:system"

  # The host-side Claude bridge (Node, no dependencies needed for its tests)
  step "Tests: Claude bridge", "node --test 'claude_bridge/*.test.ts'"

  # w1-ds: the pure JS helpers the money field and charts share (amount parsing, paste)
  step "Tests: JavaScript", "node --test 'test/javascript/*_test.mjs' 'test/javascript/utils/*_test.mjs'"
end
