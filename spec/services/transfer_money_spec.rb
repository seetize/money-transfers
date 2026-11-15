require "rails_helper"

RSpec.describe TransferMoney do
  subject(:transfer_money) do
    described_class.call(
      from_account_id: from.id,
      to_account_id: to.id,
      amount: amount,
      idempotency_key: key
    )
  end

  let(:from) { open_account(user_id: 101, deposit: BigDecimal("100.00")) }
  let(:to) { open_account(user_id: 102) }
  let(:amount) { BigDecimal("40.00") }
  let(:key) { SecureRandom.uuid }

  it "atomically completes a transfer and writes balanced ledger entries" do
    transfer = transfer_money

    expect(transfer).to be_completed
    expect(transfer.replayed_request).to be(false)
    expect(from.reload.balance).to eq(BigDecimal("60.00"))
    expect(to.reload.balance).to eq(BigDecimal("40.00"))
    expect(transfer.ledger_entries.order(:account_id).pluck(:account_id, :amount)).to contain_exactly(
      [ from.id, BigDecimal("-40.00") ],
      [ to.id, BigDecimal("40.00") ]
    )
    expect(BalanceMismatches.call).to be_empty
  end

  it "persists insufficient funds as a stable failed result without movements" do
    transfer = described_class.call(
      from_account_id: from.id,
      to_account_id: to.id,
      amount: BigDecimal("101.00"),
      idempotency_key: key
    )

    expect(transfer).to be_failed
    expect(transfer.failure_reason).to eq("insufficient_funds")
    expect(transfer.ledger_entries).to be_empty
    expect(from.reload.balance).to eq(BigDecimal("100.00"))
    expect(to.reload.balance).to eq(BigDecimal("0.00"))
  end

  it "returns the original transfer for the same key and parameters" do
    original = transfer_money
    replayed = described_class.call(
      from_account_id: from.id, to_account_id: to.id, amount: amount, idempotency_key: key
    )

    expect(replayed.id).to eq(original.id)
    expect(replayed.replayed_request).to be(true)
    expect(Transfer.where(idempotency_key: key).count).to eq(1)
    expect(LedgerEntry.where(transfer_id: original.id).count).to eq(2)
  end

  it "rejects reuse of a key with different parameters" do
    transfer_money

    expect do
      described_class.call(
        from_account_id: from.id,
        to_account_id: to.id,
        amount: BigDecimal("39.00"),
        idempotency_key: key
      )
    end.to raise_error(TransferMoney::IdempotencyConflict)
  end

  it "rolls everything back when ledger insertion fails" do
    allow(LedgerEntry).to receive(:insert_all!).and_raise(ActiveRecord::StatementInvalid, "write failed")

    expect { transfer_money }.to raise_error(ActiveRecord::StatementInvalid, "write failed")
    expect(from.reload.balance).to eq(BigDecimal("100.00"))
    expect(to.reload.balance).to eq(BigDecimal("0.00"))
    expect(Transfer.where(idempotency_key: key)).to be_empty
  end

  it "rejects Float, non-positive, over-precise and out-of-range amounts" do
    [ 0.1, "0", "-1.00", "1.001", "10000000000000000.00" ].each do |invalid_amount|
      expect do
        described_class.call(
          from_account_id: from.id,
          to_account_id: to.id,
          amount: invalid_amount,
          idempotency_key: SecureRandom.uuid
        )
      end.to raise_error(TransferMoney::InvalidAmount)
    end
  end

  it "rejects a transfer to the same account before writing" do
    expect do
      described_class.call(
        from_account_id: from.id,
        to_account_id: from.id,
        amount: amount,
        idempotency_key: key
      )
    end.to raise_error(TransferMoney::SameAccount)

    expect(Transfer.where(idempotency_key: key)).to be_empty
  end

  it "raises a typed error when an account does not exist" do
    expect do
      described_class.call(
        from_account_id: from.id,
        to_account_id: 999_999,
        amount: amount,
        idempotency_key: key
      )
    end.to raise_error(TransferMoney::AccountNotFound)
  end

  it "retries transient database failures from the outer transaction boundary" do
    service = described_class.new(
      from_account_id: 1,
      to_account_id: 2,
      amount: BigDecimal("1"),
      idempotency_key: "retryable"
    )
    allow(service).to receive(:sleep)
    allow(service).to receive(:perform).and_invoke(
      -> { raise ActiveRecord::Deadlocked, "deadlock" },
      -> { raise ActiveRecord::SerializationFailure, "serialization" },
      -> { :completed }
    )

    expect(service.call).to eq(:completed)
    expect(service).to have_received(:perform).exactly(3).times
    expect(service).to have_received(:sleep).twice
  end

  it "surfaces a transient database failure after the retry budget is exhausted" do
    service = described_class.new(
      from_account_id: 1,
      to_account_id: 2,
      amount: BigDecimal("1"),
      idempotency_key: "retry-exhausted"
    )
    allow(service).to receive(:sleep)
    allow(service).to receive(:perform).and_raise(ActiveRecord::LockWaitTimeout, "timeout")

    expect { service.call }.to raise_error(ActiveRecord::LockWaitTimeout, "timeout")
    expect(service).to have_received(:perform).exactly(3).times
    expect(service).to have_received(:sleep).twice
  end
end
