require "rails_helper"

RSpec.describe "Database invariants" do
  let(:connection) { ActiveRecord::Base.connection }
  let!(:from) { open_account(user_id: 1, deposit: BigDecimal("100")) }
  let!(:to) { open_account(user_id: 2) }

  def expect_database_rejection(&block)
    expect do
      ApplicationRecord.transaction(requires_new: true, &block)
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "rejects a negative account balance even when validations are bypassed" do
    expect_database_rejection { from.update_columns(balance: BigDecimal("-0.01")) }
  end

  it "rejects non-positive transfer amounts and equal accounts" do
    expect_database_rejection do
      connection.execute(<<~SQL)
        INSERT INTO transfers
          (from_account_id, to_account_id, amount, status, idempotency_key, created_at, updated_at)
        VALUES (#{from.id}, #{to.id}, 0, 'pending', 'zero', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end
    expect_database_rejection do
      connection.execute(<<~SQL)
        INSERT INTO transfers
          (from_account_id, to_account_id, amount, status, idempotency_key, created_at, updated_at)
        VALUES (#{from.id}, #{from.id}, 1, 'pending', 'same', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end
  end

  it "enforces unique idempotency keys" do
    Transfer.create!(from_account: from, to_account: to, amount: 1, idempotency_key: "one-key")

    expect_database_rejection do
      connection.execute(<<~SQL)
        INSERT INTO transfers
          (from_account_id, to_account_id, amount, status, idempotency_key, created_at, updated_at)
        VALUES (#{from.id}, #{to.id}, 1, 'pending', 'one-key', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end
  end

  it "enforces foreign keys and the status set" do
    expect_database_rejection do
      connection.execute(<<~SQL)
        INSERT INTO transfers
          (from_account_id, to_account_id, amount, status, idempotency_key, created_at, updated_at)
        VALUES (-1, #{to.id}, 1, 'pending', 'missing', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end
    expect_database_rejection do
      connection.execute(<<~SQL)
        INSERT INTO transfers
          (from_account_id, to_account_id, amount, status, idempotency_key, created_at, updated_at)
        VALUES (#{from.id}, #{to.id}, 1, 'unknown', 'status', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end
  end

  it "makes the ledger append-only" do
    entry = from.ledger_entries.find_by!(kind: "deposit")

    expect_database_rejection { entry.update_columns(amount: BigDecimal("99")) }
    expect_database_rejection { entry.delete }
  end

  it "rejects a completed transfer without its exact debit and credit at constraint time" do
    expect_database_rejection do
      transfer = Transfer.create!(
        from_account: from,
        to_account: to,
        amount: 10,
        idempotency_key: "missing-credit"
      )
      LedgerEntry.create!(transfer: transfer, account: from, amount: -10, kind: "transfer")
      transfer.update!(status: "completed")
      connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
    end
  end

  it "prevents mutation of transfer identity and terminal status" do
    transfer = TransferMoney.call(
      from_account_id: from.id,
      to_account_id: to.id,
      amount: BigDecimal("10"),
      idempotency_key: "immutable"
    )

    expect_database_rejection { transfer.update_columns(amount: BigDecimal("11")) }
    expect_database_rejection { transfer.update_columns(status: "failed", failure_reason: "changed") }
  end
end
