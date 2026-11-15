# Mirrors the assignment's read/check/write algorithm. Only key plumbing and the
# return value are adapted to the current service contract. The extra barrier
# forces every worker to read the same stale balances before any write.
module UnsafeTransferAdapter
  def call(from_account_id:, to_account_id:, amount:, idempotency_key:)
    from = Account.find(from_account_id)
    to = Account.find(to_account_id)
    amount = BigDecimal(amount.to_s)
    raise "Insufficient funds" if from.balance < amount
    raise "unsafe barrier timed out" unless unsafe_barrier.wait(10)

    transfer = Transfer.create!(from_account: from, to_account: to, amount: amount,
      status: "pending", idempotency_key: idempotency_key)
    from.update!(balance: from.balance - amount)
    to.update!(balance: to.balance + amount)
    LedgerEntry.create!(transfer: transfer, account: from, amount: -amount)
    LedgerEntry.create!(transfer: transfer, account: to, amount: amount)
    transfer.update!(status: "completed")
    transfer
  end

  def unsafe_barrier
    @unsafe_barrier ||= Concurrent::CyclicBarrier.new(20)
  end
end

raise "negative control is test-only" unless Rails.env.test?
TransferMoney.singleton_class.prepend(UnsafeTransferAdapter)
