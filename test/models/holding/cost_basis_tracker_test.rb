require "test_helper"

class Holding::CostBasisTrackerTest < ActiveSupport::TestCase
  setup do
    @tracker = Holding::CostBasisTracker.new
  end

  test "average cost is nil with no trades" do
    assert_nil @tracker.average_cost
    assert_not @tracker.unknown?
  end

  test "weighted average across several buys" do
    @tracker.apply(BigDecimal("100"), BigDecimal("10"))
    @tracker.apply(BigDecimal("200"), BigDecimal("10"))

    assert_equal BigDecimal("150"), @tracker.average_cost
  end

  test "a partial sell leaves the per-unit average unchanged" do
    @tracker.apply(BigDecimal("100"), BigDecimal("10"))
    @tracker.apply(BigDecimal("200"), BigDecimal("10"))

    # The sale price does not touch the basis: units are relieved at the average
    @tracker.apply(BigDecimal("999"), BigDecimal("-5"))

    assert_equal BigDecimal("150"), @tracker.average_cost
  end

  test "a partial sell then a buy averages only the units still held" do
    @tracker.apply(BigDecimal("100"), BigDecimal("10"))
    @tracker.apply(nil, BigDecimal("-5"))
    @tracker.apply(BigDecimal("200"), BigDecimal("5"))

    # (5 x 100 + 5 x 200) / 10, not (10 x 100 + 5 x 200) / 15
    assert_equal BigDecimal("150"), @tracker.average_cost
  end

  test "the basis starts again after a full liquidation and repurchase" do
    @tracker.apply(BigDecimal("100"), BigDecimal("10"))
    @tracker.apply(BigDecimal("300"), BigDecimal("-10"))

    assert_nil @tracker.average_cost

    @tracker.apply(BigDecimal("300"), BigDecimal("10"))

    # Only the repurchased lot is held, not (100 + 300) / 2
    assert_equal BigDecimal("300"), @tracker.average_cost
  end

  test "an over-sell cannot drive quantity or basis negative" do
    @tracker.apply(BigDecimal("100"), BigDecimal("5"))
    @tracker.apply(BigDecimal("100"), BigDecimal("-10"))

    assert_nil @tracker.average_cost
  end

  test "a sell with nothing held does nothing" do
    @tracker.apply(BigDecimal("100"), BigDecimal("-5"))

    assert_nil @tracker.average_cost
  end

  test "float inputs still reset on a full liquidation" do
    @tracker.apply(100.0, 10.0)
    @tracker.apply(300.0, -10.0)

    assert_nil @tracker.average_cost

    @tracker.apply(300.0, 10.0)

    assert_equal BigDecimal("300"), @tracker.average_cost
  end

  test "a buy with no converted price makes the basis unknown while it is held" do
    @tracker.apply(BigDecimal("100"), BigDecimal("10"))
    @tracker.apply(nil, BigDecimal("5"))

    assert @tracker.unknown?
    assert_nil @tracker.average_cost

    # A partial sell does not release it: some of those units can still be held
    @tracker.apply(nil, BigDecimal("-5"))
    assert @tracker.unknown?
    assert_nil @tracker.average_cost
  end

  test "the unknown state is released when the position closes" do
    @tracker.apply(nil, BigDecimal("5"))
    @tracker.apply(nil, BigDecimal("-5"))

    assert_not @tracker.unknown?

    @tracker.apply(BigDecimal("120"), BigDecimal("2"))
    assert_equal BigDecimal("120"), @tracker.average_cost
  end
end
