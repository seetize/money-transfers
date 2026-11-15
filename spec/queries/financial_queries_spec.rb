require "rails_helper"

RSpec.describe "Financial queries" do
  describe BalanceMismatches do
    it "includes accounts with no entries and returns the expected demo differences" do
      load Rails.root.join("db/seeds.rb")

      rows = described_class.call.index_by(&:id)

      expect(rows.keys).to contain_exactly(1, 2, 3)
      expect(rows[1].ledger_balance).to eq(BigDecimal("-100.00"))
      expect(rows[1].difference).to eq(BigDecimal("1100.00"))
      expect(rows[2].ledger_balance).to eq(BigDecimal("-100.00"))
      expect(rows[2].difference).to eq(BigDecimal("600.00"))
      expect(rows[3].ledger_balance).to eq(BigDecimal("200.00"))
      expect(rows[3].difference).to eq(BigDecimal("-200.00"))
    end
  end

  describe UnbalancedTransfers do
    it "finds a transfer whose movements do not net to zero" do
      from = open_account(user_id: 1)
      to = open_account(user_id: 2)
      transfer = Transfer.create!(
        from_account: from,
        to_account: to,
        amount: BigDecimal("10.00"),
        idempotency_key: SecureRandom.uuid
      )
      LedgerEntry.create!(transfer: transfer, account: from, amount: BigDecimal("-10.00"), kind: "transfer")

      result = described_class.call.first

      expect(result.id).to eq(transfer.id)
      expect(result.ledger_net).to eq(BigDecimal("-10.00"))
      expect(result.entries_count).to eq(1)
    end
  end

  describe TopSenders do
    it "aggregates all sender accounts by user and excludes old or failed transfers" do
      user_account_one = open_account(user_id: 10, deposit: BigDecimal("1000"))
      user_account_two = open_account(user_id: 10, deposit: BigDecimal("1000"))
      other = open_account(user_id: 20, deposit: BigDecimal("1000"))
      receiver = open_account(user_id: 30)

      complete_transfer(from: user_account_one, to: receiver, amount: BigDecimal("100"), created_at: 2.days.ago)
      complete_transfer(from: user_account_two, to: receiver, amount: BigDecimal("150"), created_at: 1.day.ago)
      complete_transfer(from: other, to: receiver, amount: BigDecimal("200"), created_at: 3.days.ago)
      complete_transfer(from: other, to: receiver, amount: BigDecimal("900"), created_at: 31.days.ago)

      expect(described_class.call(since: 30.days.ago)).to eq(
        10 => BigDecimal("250"),
        20 => BigDecimal("200")
      )
    end
  end

  describe DormantAccounts do
    it "returns accounts with only old movements and accounts with no movements" do
      active = open_account(user_id: 1, deposit: BigDecimal("10"))
      old = open_account(user_id: 2, deposit: BigDecimal("10"), entry_created_at: 91.days.ago)
      never_used = open_account(user_id: 3)

      expect(described_class.call(since: 90.days.ago).ids).to contain_exactly(old.id, never_used.id)
      expect(described_class.call(since: 90.days.ago).ids).not_to include(active.id)
    end
  end
end
