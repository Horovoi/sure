require "test_helper"

class ImportJobTest < ActiveJob::TestCase
  test "an importing import is published" do
    import = imports(:transaction)
    import.update_column(:status, "importing")
    import.expects(:publish).once

    ImportJob.perform_now(import)
  end

  test "a duplicate or late job for an import in another state does nothing" do
    import = imports(:transaction)

    %w[pending complete reverting reverted].each do |state|
      import.update_column(:status, state)
      import.expects(:publish).never

      ImportJob.perform_now(import)
    end
  end
end
