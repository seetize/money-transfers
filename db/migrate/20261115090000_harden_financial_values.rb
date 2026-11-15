class HardenFinancialValues < ActiveRecord::Migration[7.2]
  def up
    remove_check_constraint :transfers, name: "transfers_failure_reason_matches_status"
    add_check_constraint :transfers, "(status = 'failed') = (failure_reason IS NOT NULL)",
      name: "transfers_failure_reason_matches_status"
    remove_check_constraint :transfers, name: "transfers_idempotency_key_present"
    add_check_constraint :transfers, "char_length(btrim(idempotency_key)) > 0",
      name: "transfers_idempotency_key_present"
    add_check_constraint :accounts, "balance <> 'NaN'::numeric", name: "accounts_balance_finite"
    add_check_constraint :transfers, "amount <> 'NaN'::numeric", name: "transfers_amount_finite"
    add_check_constraint :ledger_entries, "amount <> 'NaN'::numeric", name: "ledger_amount_finite"
    add_check_constraint :ledger_entries, "kind <> 'deposit' OR amount > 0", name: "ledger_deposit_positive"
    execute <<~SQL
      DROP TRIGGER transfers_immutable_identity_and_status ON transfers;
      CREATE TRIGGER transfers_immutable_identity_and_status
      BEFORE UPDATE OF from_account_id, to_account_id, amount, idempotency_key, status, failure_reason ON transfers
      FOR EACH ROW EXECUTE FUNCTION forbid_transfer_identity_mutation();

      CREATE FUNCTION forbid_transfer_deletion() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'transfers are retained for idempotency' USING ERRCODE = 'check_violation';
      END;
      $$;
      CREATE TRIGGER transfers_no_delete BEFORE DELETE ON transfers
      FOR EACH ROW EXECUTE FUNCTION forbid_transfer_deletion();
    SQL
  end

  def down
    remove_check_constraint :transfers, name: "transfers_failure_reason_matches_status"
    add_check_constraint :transfers,
      "(status = 'failed' AND failure_reason IS NOT NULL) OR (status IN ('pending', 'completed') AND failure_reason IS NULL)",
      name: "transfers_failure_reason_matches_status"
    remove_check_constraint :transfers, name: "transfers_idempotency_key_present"
    add_check_constraint :transfers, "char_length(idempotency_key) > 0", name: "transfers_idempotency_key_present"
    execute <<~SQL
      DROP TRIGGER transfers_no_delete ON transfers;
      DROP FUNCTION forbid_transfer_deletion();
      DROP TRIGGER transfers_immutable_identity_and_status ON transfers;
      CREATE TRIGGER transfers_immutable_identity_and_status
      BEFORE UPDATE OF from_account_id, to_account_id, amount, idempotency_key, status ON transfers
      FOR EACH ROW EXECUTE FUNCTION forbid_transfer_identity_mutation();
    SQL
    remove_check_constraint :ledger_entries, name: "ledger_deposit_positive"
    remove_check_constraint :ledger_entries, name: "ledger_amount_finite"
    remove_check_constraint :transfers, name: "transfers_amount_finite"
    remove_check_constraint :accounts, name: "accounts_balance_finite"
  end
end
