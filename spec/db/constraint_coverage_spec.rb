require "rails_helper"

RSpec.describe "Named PostgreSQL constraints" do
  let!(:from) { open_account(user_id: 1, deposit: BigDecimal("100")) }
  let!(:to) { open_account(user_id: 2) }
  let(:transfer_attrs) do
    { from_account_id: from.id, to_account_id: to.id, amount: "10", status: "pending", idempotency_key: "db-check" }
  end

  def rejects_constraint(name)
    expect do
      ApplicationRecord.transaction(requires_new: true) { yield }
    end.to raise_error(ActiveRecord::StatementInvalid) { |error|
      expect(error.cause.result.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME)).to eq(name)
    }
  end

  {
    "transfers_amount_positive" => { amount: "0" },
    "transfers_amount_finite" => { amount: "NaN" },
    "transfers_status_valid" => { status: "unknown" },
    "transfers_idempotency_key_present" => { idempotency_key: "   " },
    "transfers_failure_reason_matches_status" => { status: "failed" }
  }.each do |name, overrides|
    it "enforces #{name} without model validations" do
      rejects_constraint(name) { Transfer.insert_all!([ transfer_attrs.merge(overrides) ]) }
    end
  end

  it "enforces distinct accounts" do
    rejects_constraint("transfers_distinct_accounts") do
      Transfer.insert_all!([ transfer_attrs.merge(to_account_id: from.id) ])
    end
  end

  {
    "accounts_balance_non_negative" => "-1",
    "accounts_balance_finite" => "NaN"
  }.each do |name, value|
    it "enforces #{name}" do
      rejects_constraint(name) { from.update_columns(balance: value) }
    end
  end

  {
    "ledger_amount_non_zero" => { amount: "0", kind: "deposit" },
    "ledger_amount_finite" => { amount: "NaN", kind: "deposit" },
    "ledger_kind_valid" => { amount: "1", kind: "unknown" },
    "ledger_kind_matches_transfer" => { amount: "1", kind: "transfer" },
    "ledger_deposit_positive" => { amount: "-1", kind: "deposit" }
  }.each do |name, overrides|
    it "enforces #{name}" do
      rejects_constraint(name) do
        LedgerEntry.insert_all!([ { account_id: from.id, created_at: Time.current, **overrides } ])
      end
    end
  end

  it "enforces every foreign key independently" do
    checks = [
      [ Transfer, transfer_attrs.merge(from_account_id: 999_999) ],
      [ Transfer, transfer_attrs.merge(to_account_id: 999_999) ],
      [ LedgerEntry, { account_id: 999_999, amount: "1", kind: "deposit", created_at: Time.current } ],
      [ LedgerEntry, { account_id: from.id, transfer_id: 999_999, amount: "1", kind: "transfer", created_at: Time.current } ]
    ]
    checks.each do |model, attrs|
      expect { model.transaction(requires_new: true) { model.insert_all!([ attrs ]) } }
        .to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  it "enforces every NOT NULL column without model validations" do
    rows = {
      Account => { user_id: 3, balance: "0", created_at: Time.current, updated_at: Time.current },
      Transfer => transfer_attrs.merge(created_at: Time.current, updated_at: Time.current),
      LedgerEntry => { account_id: from.id, amount: "1", kind: "deposit", created_at: Time.current }
    }
    rows.each do |model, attrs|
      model.columns.reject { |column| column.null || column.name == "id" }.each do |column|
        expect do
          model.transaction(requires_new: true) { model.insert_all!([ attrs.merge(column.name.to_sym => nil) ]) }
        end.to raise_error(ActiveRecord::NotNullViolation)
      end
    end
  end

  it "enforces the transfer/account unique ledger pair" do
    transfer_id = Transfer.insert_all!([ transfer_attrs ], returning: %w[id]).rows.first.first
    attrs = { account_id: from.id, transfer_id: transfer_id, amount: "-10", kind: "transfer", created_at: Time.current }
    LedgerEntry.insert_all!([ attrs ])
    rejects_constraint("index_ledger_entries_on_transfer_and_account") { LedgerEntry.insert_all!([ attrs ]) }
  end

  it "retains failed transfers for idempotency and prevents changing their reason" do
    transfer = Transfer.create!(**transfer_attrs, status: "failed", failure_reason: "insufficient_funds")
    expect { transfer.delete }.to raise_error(ActiveRecord::StatementInvalid, /retained for idempotency/)
    expect { transfer.update_columns(failure_reason: "changed") }
      .to raise_error(ActiveRecord::StatementInvalid, /invalid transfer status transition/)
  end

  [ "missing", "wrong_amount", "wrong_account", "wrong_sign", "failed" ].each do |scenario|
    it "rejects #{scenario} terminal ledger at actual commit" do
      outsider = open_account(user_id: 3)
      expect do
        Transfer.transaction do
          transfer = Transfer.create!(**transfer_attrs)
          LedgerEntry.create!(transfer: transfer, account: from, amount: "-10", kind: "transfer")
          unless scenario == "missing"
            LedgerEntry.create!(
              transfer: transfer, account: scenario == "wrong_account" ? outsider : to,
              amount: { "wrong_amount" => "9", "wrong_sign" => "-10" }.fetch(scenario, "10"), kind: "transfer"
            )
          end
          transfer.update!(status: scenario == "failed" ? "failed" : "completed",
            failure_reason: scenario == "failed" ? "insufficient_funds" : nil)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /ledger entries/)
    end
  end
end
