now = Time.current

Account.transaction do
  accounts = [
    Account.create!(id: 1, user_id: 101, balance: BigDecimal("1000.00")),
    Account.create!(id: 2, user_id: 102, balance: BigDecimal("500.00")),
    Account.create!(id: 3, user_id: 103, balance: BigDecimal("0.00"))
  ]

  transfer_one = Transfer.create!(
    id: 1, from_account: accounts[0], to_account: accounts[1], amount: BigDecimal("100.00"),
    status: "pending", idempotency_key: "demo-1", created_at: now - 10.days
  )
  LedgerEntry.create!(transfer: transfer_one, account: accounts[0], amount: BigDecimal("-100.00"), kind: "transfer")
  LedgerEntry.create!(transfer: transfer_one, account: accounts[1], amount: BigDecimal("100.00"), kind: "transfer")
  transfer_one.update!(status: "completed")

  transfer_two = Transfer.create!(
    id: 2, from_account: accounts[1], to_account: accounts[2], amount: BigDecimal("200.00"),
    status: "pending", idempotency_key: "demo-2", created_at: now - 5.days
  )
  LedgerEntry.create!(transfer: transfer_two, account: accounts[1], amount: BigDecimal("-200.00"), kind: "transfer")
  LedgerEntry.create!(transfer: transfer_two, account: accounts[2], amount: BigDecimal("200.00"), kind: "transfer")
  transfer_two.update!(status: "completed")

  Transfer.create!(
    id: 3, from_account: accounts[0], to_account: accounts[2], amount: BigDecimal("50.00"),
    status: "failed", failure_reason: "insufficient_funds", idempotency_key: "demo-3", created_at: now - 1.day
  )
end

[ Account, Transfer, LedgerEntry ].each do |model|
  ActiveRecord::Base.connection.reset_pk_sequence!(model.table_name)
end
