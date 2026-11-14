require "test_helper"

class Eval::RunTest < ActiveSupport::TestCase
  class StubRunner < Eval::Runners::Base
    attr_accessor :on_process

    protected
      def process_samples
        on_process&.call
        record_result(sample: eval_run.dataset.samples.first, actual_output: { "category_name" => "Food" }, correct: true)
      end

      def calculate_metrics
        { "accuracy" => 100.0 }
      end
  end

  setup do
    dataset = Eval::Dataset.create!(name: "run_test_#{SecureRandom.hex(4)}", eval_type: "categorization", version: "1.0")
    dataset.samples.create!(input_data: { "id" => "1" }, expected_output: { "category_name" => "Food" }, difficulty: "easy")
    @run = Eval::Run.create!(dataset: dataset, provider: "openai", model: "gpt-4.1", name: "run")
  end

  test "a run goes pending, running, completed" do
    assert @run.pending?

    StubRunner.new(@run).run

    assert @run.reload.completed?
    assert_equal({ "accuracy" => 100.0 }, @run.metrics)
    assert_not_nil @run.started_at
    assert_not_nil @run.duration_seconds
  end

  test "an interrupted run is marked failed instead of staying running" do
    runner = StubRunner.new(@run)
    runner.on_process = -> { raise Interrupt }

    assert_raises(Interrupt) { runner.run }

    @run.reload
    assert @run.failed?
    assert_match "Interrupt", @run.error_message
    assert_not_nil @run.completed_at
  end

  test "a failing run is marked failed with the error" do
    runner = StubRunner.new(@run)
    runner.on_process = -> { raise "provider down" }

    assert_raises(RuntimeError) { runner.run }

    assert @run.reload.failed?
    assert_equal "RuntimeError: provider down", @run.error_message
  end

  test "a finished run cannot be run again, so results are not mixed" do
    StubRunner.new(@run).run
    assert_equal 1, @run.results.count

    assert_raises(Eval::Runners::Base::AlreadyRunError) { StubRunner.new(@run.reload).run }

    assert_equal 1, @run.results.count
    assert @run.reload.completed?
  end
end
