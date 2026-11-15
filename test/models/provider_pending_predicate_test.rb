require "test_helper"

class ProviderPendingPredicateTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @mono_hold = entry("m1", "monobank", { "monobank" => { "pending" => true } })
    @mono_posted = entry("m2", "monobank", { "monobank" => { "pending" => false } })
    @other_hold = entry("o1", "lunchflow", { "lunchflow" => { "pending" => true } })
    @mono_flag_other_source = entry("x1", "lunchflow", { "monobank" => { "pending" => true } })
  end

  test "pending_sql without a provider matches any provider's flag" do
    ids = Transaction.where(Transaction.pending_sql).pluck(:id)

    assert_includes ids, @mono_hold.entryable_id
    assert_includes ids, @other_hold.entryable_id
    assert_not_includes ids, @mono_posted.entryable_id
  end

  test "pending_sql with a provider matches only its flag, under any table alias" do
    ids = Transaction.from("transactions t").where(Transaction.pending_sql("t", provider: "monobank")).pluck("t.id")

    assert_includes ids, @mono_hold.entryable_id
    assert_includes ids, @mono_flag_other_source.entryable_id
    assert_not_includes ids, @other_hold.entryable_id
    assert_not_includes ids, @mono_posted.entryable_id
  end

  test "pending_sql quotes the provider key" do
    assert_nothing_raised { Transaction.where(Transaction.pending_sql(provider: "it's")).to_a }
  end

  test "Entry.pending_from takes the provider's own holds" do
    assert_equal [ @mono_hold.id ], @account.entries.pending_from("monobank").pluck(:id)
    assert_equal [ @other_hold.id ], @account.entries.pending_from(:lunchflow).pluck(:id)
  end

  private
    def entry(external_id, source, extra)
      @account.entries.create!(date: Date.current, amount: 1, currency: "USD", name: external_id, external_id: external_id, source: source,
        entryable: Transaction.new(extra: extra))
    end
end
