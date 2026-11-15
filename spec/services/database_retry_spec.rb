require "rails_helper"

RSpec.describe "Retries after real PostgreSQL transaction errors" do
  { "deadlock_detected" => "40P01", "serialization_failure" => "40001", "lock_not_available" => "55P03" }.each do |name, sqlstate|
    it "rolls back balance and idempotency claim before retrying #{name}" do
      from = open_account(user_id: 1, deposit: BigDecimal("100"))
      to = open_account(user_id: 2)
      service = TransferMoney.new(from_account_id: from.id, to_account_id: to.id,
        amount: "10.00", idempotency_key: "database-retry")
      calls = 0
      allow(service).to receive(:create_ledger_entries!).and_wrap_original do |original, *args|
        calls += 1
        if calls == 1
          # Raise inside PostgreSQL after both balances have already been updated.
          # The adapter must translate SQLSTATE and the service must retry a new transaction.
          Transfer.connection.execute("DO $$ BEGIN RAISE EXCEPTION 'injected transient error' USING ERRCODE = '#{sqlstate}'; END $$;")
        else
          original.call(*args)
        end
      end
      transfer = service.call
      expect(calls).to eq(2)
      expect(transfer).to be_completed
      expect(Transfer.count).to eq(1)
      expect(LedgerEntry.where(kind: "transfer").count).to eq(2)
      expect(from.reload.balance).to eq(BigDecimal("90"))
      expect(to.reload.balance).to eq(BigDecimal("10"))
      expect(BalanceMismatches.call).to be_empty
    end
  end
end
