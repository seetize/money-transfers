require "rails_helper"

RSpec.describe "Parallel transfers" do
  self.use_transactional_tests = false

  before { truncate_financial_tables }
  after { truncate_financial_tables }

  def truncate_financial_tables
    ActiveRecord::Base.connection.execute(
      "TRUNCATE ledger_entries, transfers, accounts RESTART IDENTITY CASCADE"
    )
  end

  def in_parallel(count)
    barrier = Concurrent::CyclicBarrier.new(count)
    threads = Array.new(count) do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          raise "parallel barrier timed out" unless barrier.wait(10)

          yield index
        end
      rescue StandardError => error
        error
      end
    end
    # Always wait for all workers before cleanup, even when one worker failed.
    results = threads.map(&:value)
    raise results.find { |result| result.is_a?(Exception) } if results.any? { |result| result.is_a?(Exception) }

    results
  end

  it "cannot debit more than the available balance and keeps ledger reconciled" do
    from = open_account(user_id: 101, deposit: BigDecimal("100"))
    to = open_account(user_id: 102)

    results = in_parallel(20) do
      TransferMoney.call(
        from_account_id: from.id,
        to_account_id: to.id,
        amount: BigDecimal("10"),
        idempotency_key: SecureRandom.uuid
      )
    end

    expect(results.count(&:completed?)).to eq(10)
    expect(results.count(&:failed?)).to eq(10)
    expect(from.reload.balance).to eq(BigDecimal("0"))
    expect(to.reload.balance).to eq(BigDecimal("100"))
    expect(Account.sum(:balance)).to eq(BigDecimal("100"))
    expect(LedgerEntry.where(kind: "transfer").sum(:amount)).to eq(BigDecimal("0"))
    expect(LedgerEntry.where(kind: "transfer").count).to eq(20)
    expect(BalanceMismatches.call).to be_empty
    expect(UnbalancedTransfers.call).to be_empty
    expect(InvalidTransferLedgers.call).to be_empty
  end

  it "executes one transfer when many threads use the same idempotency key" do
    from = open_account(user_id: 101, deposit: BigDecimal("100"))
    to = open_account(user_id: 102)
    key = SecureRandom.uuid

    results = in_parallel(10) do
      TransferMoney.call(
        from_account_id: from.id,
        to_account_id: to.id,
        amount: BigDecimal("10"),
        idempotency_key: key
      )
    end

    expect(results.map(&:id).uniq.one?).to be(true)
    expect(Transfer.where(idempotency_key: key).count).to eq(1)
    expect(LedgerEntry.where(kind: "transfer").count).to eq(2)
    expect(from.reload.balance).to eq(BigDecimal("90"))
  end

  it "takes locks in a stable order for opposing transfers" do
    account_a = open_account(user_id: 101, deposit: BigDecimal("100"))
    account_b = open_account(user_id: 102, deposit: BigDecimal("100"))

    results = in_parallel(20) do |index|
      from, to = index.even? ? [ account_a, account_b ] : [ account_b, account_a ]
      TransferMoney.call(
        from_account_id: from.id,
        to_account_id: to.id,
        amount: BigDecimal("1"),
        idempotency_key: SecureRandom.uuid
      )
    end

    expect(results).to all(be_completed)
    expect(account_a.reload.balance).to eq(BigDecimal("100"))
    expect(account_b.reload.balance).to eq(BigDecimal("100"))
    expect(BalanceMismatches.call).to be_empty
  end

  it "reconciles 50 simultaneous transfers across five accounts" do
    accounts = Array.new(5) { |index| open_account(user_id: index + 1, deposit: BigDecimal("100")) }
    random = Random.new(20261115)
    requests = Array.new(50) do
      from, to = accounts.sample(2, random: random)
      [ from.id, to.id, BigDecimal(random.rand(1..20).to_s) ]
    end
    results = in_parallel(50) do |index|
      from_id, to_id, amount = requests.fetch(index)
      TransferMoney.call(from_account_id: from_id, to_account_id: to_id,
        amount: amount, idempotency_key: "random-#{index}")
    end
    expect(results.count).to eq(50)
    expect(Account.where("balance < 0")).to be_empty
    expect(Account.sum(:balance)).to eq(BigDecimal("500"))
    expect(BalanceMismatches.call).to be_empty
    expect(InvalidTransferLedgers.call).to be_empty
    expect(LedgerEntry.where(kind: "transfer").count).to eq(results.count(&:completed?) * 2)
  end
end
