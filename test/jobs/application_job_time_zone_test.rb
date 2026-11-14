require "test_helper"

class ApplicationJobTimeZoneTest < ActiveJob::TestCase
  class ZoneProbeJob < ApplicationJob
    cattr_accessor :seen_zone
    def perform(_subject)
      self.class.seen_zone = Time.zone.name
    end
  end

  test "a job about a family runs in the family time zone" do
    family = families(:dylan_family)
    family.update!(timezone: "Europe/Helsinki")

    ZoneProbeJob.perform_now(family)
    assert_equal "Europe/Helsinki", ZoneProbeJob.seen_zone

    ZoneProbeJob.perform_now(family.accounts.first)
    assert_equal "Europe/Helsinki", ZoneProbeJob.seen_zone
  end

  test "other jobs keep the default zone" do
    ZoneProbeJob.perform_now("not a record")
    assert_equal Time.zone_default.name, ZoneProbeJob.seen_zone
  end
end
