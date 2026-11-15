require "rails_helper"

RSpec.describe "Transfer input contract" do
  let(:from) { open_account(user_id: 1, deposit: BigDecimal("100")) }
  let(:to) { open_account(user_id: 2) }
  let(:args) do
    { from_account_id: from.id, to_account_id: to.id, amount: "10.00", idempotency_key: "contract" }
  end

  [ 1.9, BigDecimal("1.9"), "1.9", "-1", 0, 2**63, nil, true ].each do |invalid|
    it "rejects invalid account id #{invalid.inspect}" do
      expect { TransferMoney.call(**args.merge(from_account_id: invalid)) }
        .to raise_error(TransferMoney::InvalidAccount)
      expect(Transfer.count).to eq(0)
    end
  end

  [ nil, false, [], {}, "NaN", "Infinity", "-Infinity", "1.001", "not-money" ].each do |invalid|
    it "rejects invalid amount #{invalid.inspect}" do
      expect { TransferMoney.call(**args.merge(amount: invalid)) }.to raise_error(TransferMoney::InvalidAmount)
      expect(Transfer.count).to eq(0)
    end
  end

  [ nil, 123, [], "", "   ", "x" * 256, "null\0byte" ].each do |invalid|
    it "rejects invalid key #{invalid.inspect}" do
      expect { TransferMoney.call(**args.merge(idempotency_key: invalid)) }
        .to raise_error(TransferMoney::InvalidIdempotencyKey)
    end
  end

  it "rejects an outer transaction before any write" do
    args
    Account.transaction do
      expect { TransferMoney.call(**args) }.to raise_error(TransferMoney::NestedTransaction)
    end
    expect(Transfer.count).to eq(0)
  end

  it "parses leading-zero account strings in base ten" do
    account = Account.create!(id: 10, user_id: 10, balance: "10")
    LedgerEntry.create!(account: account, amount: "10", kind: "deposit")
    transfer = TransferMoney.call(**args.merge(from_account_id: "010"))
    expect(transfer.from_account_id).to eq(10)
    expect(account.reload.balance).to eq(BigDecimal("0"))
  end

  it "returns a stable failure if the recipient balance cannot fit NUMERIC(18,2)" do
    recipient = open_account(user_id: 3, deposit: TransferMoney::MAX_AMOUNT)
    request = args.merge(to_account_id: recipient.id)
    first = TransferMoney.call(**request)
    second = TransferMoney.call(**request)
    expect(first.failure_reason).to eq("balance_limit_exceeded")
    expect(second.id).to eq(first.id)
    expect(second).to be_failed
    expect(from.reload.balance).to eq(BigDecimal("100"))
    expect(recipient.reload.balance).to eq(TransferMoney::MAX_AMOUNT)
    expect(first.ledger_entries).to be_empty
    expect(BalanceMismatches.call).to be_empty
  end

  it "replays insufficient funds even after a subsequent deposit" do
    request = args.merge(amount: "101.00")
    first = TransferMoney.call(**request)
    Account.transaction do
      from.update!(balance: BigDecimal("200"))
      LedgerEntry.create!(account: from, amount: BigDecimal("100"), kind: "deposit")
    end
    second = TransferMoney.call(**request)
    expect(second.id).to eq(first.id)
    expect(second).to be_failed
    expect(second.replayed_request).to be(true)
    expect(from.reload.balance).to eq(BigDecimal("200"))
    expect(BalanceMismatches.call).to be_empty
  end

  it "does not retry a non-transient failure" do
    service = TransferMoney.new(**args)
    allow(service).to receive(:perform).and_raise(ActiveRecord::StatementInvalid, "integrity")
    expect { service.call }.to raise_error(ActiveRecord::StatementInvalid)
    expect(service).to have_received(:perform).once
  end
end
