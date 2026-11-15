class CreateCoreTables < ActiveRecord::Migration[7.2]
  def change
    create_table :accounts do |t|
      t.bigint :user_id, null: false
      t.decimal :balance, precision: 18, scale: 2, null: false, default: 0
      t.timestamps

      t.index :user_id
      t.check_constraint "balance >= 0", name: "accounts_balance_non_negative"
    end

    create_table :transfers do |t|
      t.references :from_account, null: false, foreign_key: { to_table: :accounts }
      t.references :to_account, null: false, foreign_key: { to_table: :accounts }
      t.decimal :amount, precision: 18, scale: 2, null: false
      t.string :status, null: false, default: "pending"
      t.string :idempotency_key, null: false, limit: 255
      t.string :failure_reason
      t.timestamps

      t.index :idempotency_key, unique: true
      t.index %i[from_account_id created_at]
      t.index %i[to_account_id created_at]
      t.check_constraint "amount > 0", name: "transfers_amount_positive"
      t.check_constraint "from_account_id <> to_account_id", name: "transfers_distinct_accounts"
      t.check_constraint "status IN ('pending', 'completed', 'failed')", name: "transfers_status_valid"
      t.check_constraint "char_length(idempotency_key) > 0", name: "transfers_idempotency_key_present"
      t.check_constraint <<~SQL.squish, name: "transfers_failure_reason_matches_status"
        (status = 'failed' AND failure_reason IS NOT NULL)
        OR (status IN ('pending', 'completed') AND failure_reason IS NULL)
      SQL
    end

    create_table :ledger_entries do |t|
      t.references :transfer, null: true, foreign_key: true, index: false
      t.references :account, null: false, foreign_key: true, index: false
      t.decimal :amount, precision: 18, scale: 2, null: false
      t.string :kind, null: false, default: "transfer"
      t.datetime :created_at, null: false

      t.index %i[account_id created_at]
      t.index %i[transfer_id account_id], unique: true,
        where: "transfer_id IS NOT NULL",
        name: "index_ledger_entries_on_transfer_and_account"
      t.check_constraint "amount <> 0", name: "ledger_amount_non_zero"
      t.check_constraint "kind IN ('transfer', 'deposit')", name: "ledger_kind_valid"
      t.check_constraint "(kind = 'transfer') = (transfer_id IS NOT NULL)",
        name: "ledger_kind_matches_transfer"
    end
  end
end
