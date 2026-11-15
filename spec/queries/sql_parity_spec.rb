require "rails_helper"

RSpec.describe "SQL and ActiveRecord parity" do
  def sql_rows(filename)
    ActiveRecord::Base.connection.select_all(Rails.root.join("sql", filename).read).to_a
  end

  it "runs all five SQL reports on the exact assignment seed data" do
    load Rails.root.join("db/seeds.rb")
    mismatches = sql_rows("01_balance_mismatches.sql")
    expect(mismatches.map { |row| [ row.fetch("id"), row.fetch("difference") ] }).to eq(
      [ [ 1, BigDecimal("1100") ], [ 2, BigDecimal("600") ], [ 3, BigDecimal("-200") ] ]
    )
    expect(BalanceMismatches.call.order(:id).map { |row| [ row.id, row.difference ] })
      .to eq(mismatches.map { |row| [ row["id"], row["difference"] ] })
    expect(sql_rows("02_unbalanced_transfers.sql")).to be_empty
    expect(UnbalancedTransfers.call).to be_empty
    expect(sql_rows("03_top_senders.sql").map { |row| [ row["user_id"], row["total_outgoing"] ] })
      .to eq(TopSenders.call.to_a)
    expect(TopSenders.call.to_a).to eq([ [ 102, BigDecimal("200") ], [ 101, BigDecimal("100") ] ])
    expect(sql_rows("04_dormant_accounts.sql")).to be_empty
    expect(DormantAccounts.call).to be_empty
    expect(sql_rows("05_invalid_transfer_ledgers.sql")).to be_empty
    expect(InvalidTransferLedgers.call).to be_empty
  end

  it "finds a nonzero balance with no entries but not an empty zero account" do
    bad = Account.create!(user_id: 1, balance: "1")
    open_account(user_id: 2)
    expect(BalanceMismatches.call.map(&:id)).to eq([ bad.id ])
  end

  it "shows that a pending transfer with no entries has zero net but is not completed" do
    from = open_account(user_id: 1)
    to = open_account(user_id: 2)
    transfer = Transfer.create!(from_account: from, to_account: to, amount: "10", idempotency_key: "empty")
    expect(UnbalancedTransfers.call).to be_empty
    expect(transfer).to be_pending
    # A pending transfer with a movement is structurally suspicious even if still pending.
    LedgerEntry.create!(transfer: transfer, account: from, amount: "-10", kind: "transfer")
    expect(InvalidTransferLedgers.call.map(&:id)).to eq([ transfer.id ])
  end

  it "limits top senders to five and breaks equal-volume ties by user id" do
    receiver = open_account(user_id: 100)
    6.downto(1) do |user_id|
      from = open_account(user_id: user_id)
      complete_transfer(from: from, to: receiver, amount: BigDecimal("10"))
    end
    expect(TopSenders.call.keys).to eq([ 1, 2, 3, 4, 5 ])
  end

  it "includes the exact 30-day boundary and excludes failed transfers" do
    from = open_account(user_id: 1)
    to = open_account(user_id: 2)
    boundary = 30.days.ago.change(usec: 0)
    complete_transfer(from: from, to: to, amount: BigDecimal("10"), created_at: boundary)
    complete_transfer(from: from, to: to, amount: BigDecimal("90"), created_at: boundary - 1.second)
    Transfer.create!(from_account: from, to_account: to, amount: "100", status: "failed",
      failure_reason: "insufficient_funds", idempotency_key: "failed")
    expect(TopSenders.call(since: boundary)).to eq(1 => BigDecimal("10"))
  end

  it "treats a movement exactly at the 90-day boundary as recent" do
    boundary = 90.days.ago.change(usec: 0)
    recent = open_account(user_id: 1, deposit: BigDecimal("1"), entry_created_at: boundary)
    old = open_account(user_id: 2, deposit: BigDecimal("1"), entry_created_at: boundary - 1.second)
    expect(DormantAccounts.call(since: boundary).ids).to eq([ old.id ])
    expect(DormantAccounts.call(since: boundary).ids).not_to include(recent.id)
  end
end
