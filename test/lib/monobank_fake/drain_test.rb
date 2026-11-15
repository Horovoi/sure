require "test_helper"
require Rails.root.join("script/monobank_fake/drain").to_s

class MonobankFakeDrainTestJob < ApplicationJob
  queue_as :default

  cattr_accessor :runs, default: []

  # again: [seconds, times] to enqueue itself again
  def perform(name, again = nil, fail_with = nil)
    self.class.runs << [ name, Time.current.to_i ]
    raise ArgumentError, fail_with if fail_with

    seconds, times = again
    self.class.set(wait: seconds.seconds).perform_later("#{name}+", [ seconds, times - 1 ]) if seconds && times.to_i > 1
  end
end

class MonobankFake::DrainTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    MonobankFakeDrainTestJob.runs = []
    travel_to Time.zone.parse("2026-11-15 12:00:00")
    @start = Time.current
  end

  test "runs due jobs first, then waits for scheduled ones in time order" do
    MonobankFakeDrainTestJob.perform_later("now")
    MonobankFakeDrainTestJob.set(wait: 10.minutes).perform_later("ten")
    MonobankFakeDrainTestJob.set(wait: 5.minutes).perform_later("five", [ 61, 2 ])
    MonobankFakeDrainTestJob.perform_later("now-2")

    drain.run

    assert_equal [ [ "now", 0 ], [ "now-2", 0 ], [ "five", 300 ], [ "five+", 361 ], [ "ten", 600 ] ],
                 MonobankFakeDrainTestJob.runs.map { |name, at| [ name, at - @start.to_i ] }
    assert_empty queue_adapter.enqueued_jobs
    assert_equal 5, drain.performed.size
  end

  test "stops at the job cap" do
    MonobankFakeDrainTestJob.perform_later("loop", [ 1, 1_000 ])

    error = assert_raises(MonobankFake::Drain::Error) { drain(max_jobs: 20).run }
    assert_match "more than 20 jobs", error.message
  end

  test "stops when the next job is after the time cap" do
    MonobankFakeDrainTestJob.set(wait: 3.hours).perform_later("late")

    error = assert_raises(MonobankFake::Drain::Error) { drain(max_duration: 2.hours).run }
    assert_match "after the 2 hours cap", error.message
    assert_empty MonobankFakeDrainTestJob.runs
  end

  test "a job error is raised, or recorded and the drain goes on" do
    MonobankFakeDrainTestJob.perform_later("bad", nil, "boom")
    MonobankFakeDrainTestJob.perform_later("good")

    assert_raises(ArgumentError) { drain.run }
    assert_not_includes MonobankFakeDrainTestJob.runs.map(&:first), "good"

    MonobankFakeDrainTestJob.perform_later("bad", nil, "boom")
    recording = drain(raise_errors: false)
    recording.run
    assert_equal [ { job: "MonobankFakeDrainTestJob", error: "ArgumentError: boom" } ], recording.errors.uniq
    assert_includes MonobankFakeDrainTestJob.runs.map(&:first), "good"
  end

  test "refuses an adapter that is not the test adapter" do
    error = assert_raises(MonobankFake::Drain::Error) do
      MonobankFake::Drain.new(adapter: ActiveJob::QueueAdapters::InlineAdapter.new, wait: ->(_) { })
    end
    assert_match "needs ActiveJob's :test adapter", error.message
  end

  test "a wait that does not reach the job's time is an error, not a loop" do
    MonobankFakeDrainTestJob.set(wait: 1.minute).perform_later("later")

    stuck = MonobankFake::Drain.new(adapter: queue_adapter, wait: ->(_) { })
    assert_raises(MonobankFake::Drain::Error) { stuck.run }
  end

  test "wait_until only waits forward" do
    waits = []
    drain = MonobankFake::Drain.new(adapter: queue_adapter, wait: ->(time) { waits << time })

    drain.wait_until(@start - 1.minute)
    drain.wait_until(@start + 1.minute)

    assert_equal [ @start + 1.minute ], waits
  end

  private

    def drain(**options)
      @drains ||= {}
      @drains[options] ||= MonobankFake::Drain.new(adapter: queue_adapter, wait: ->(time) { travel_to(Time.at(time.to_r.ceil)) }, **options)
    end
end
