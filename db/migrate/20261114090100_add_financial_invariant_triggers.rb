class AddFinancialInvariantTriggers < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      CREATE FUNCTION forbid_ledger_mutation() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'ledger_entries is append-only' USING ERRCODE = 'check_violation';
      END;
      $$;

      CREATE TRIGGER ledger_entries_append_only
      BEFORE UPDATE OR DELETE ON ledger_entries
      FOR EACH ROW EXECUTE FUNCTION forbid_ledger_mutation();

      CREATE FUNCTION forbid_transfer_identity_mutation() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.from_account_id <> OLD.from_account_id
           OR NEW.to_account_id <> OLD.to_account_id
           OR NEW.amount <> OLD.amount
           OR NEW.idempotency_key <> OLD.idempotency_key THEN
          RAISE EXCEPTION 'transfer identity is immutable' USING ERRCODE = 'check_violation';
        END IF;

        IF OLD.status <> 'pending' OR NEW.status NOT IN ('completed', 'failed') THEN
          RAISE EXCEPTION 'invalid transfer status transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END;
      $$;

      CREATE TRIGGER transfers_immutable_identity_and_status
      BEFORE UPDATE OF from_account_id, to_account_id, amount, idempotency_key, status ON transfers
      FOR EACH ROW EXECUTE FUNCTION forbid_transfer_identity_mutation();

      CREATE FUNCTION assert_transfer_ledger(checked_transfer_id bigint) RETURNS void
      LANGUAGE plpgsql AS $$
      DECLARE
        checked_transfer transfers%ROWTYPE;
        entry_count bigint;
        debit_count bigint;
        credit_count bigint;
      BEGIN
        SELECT * INTO checked_transfer FROM transfers WHERE id = checked_transfer_id;
        IF NOT FOUND OR checked_transfer.status = 'pending' THEN
          RETURN;
        END IF;

        SELECT COUNT(*),
               COUNT(*) FILTER (
                 WHERE account_id = checked_transfer.from_account_id
                   AND amount = -checked_transfer.amount
               ),
               COUNT(*) FILTER (
                 WHERE account_id = checked_transfer.to_account_id
                   AND amount = checked_transfer.amount
               )
          INTO entry_count, debit_count, credit_count
          FROM ledger_entries
         WHERE transfer_id = checked_transfer_id;

        IF checked_transfer.status = 'completed'
           AND NOT (entry_count = 2 AND debit_count = 1 AND credit_count = 1) THEN
          RAISE EXCEPTION 'completed transfer % has invalid ledger entries', checked_transfer_id
            USING ERRCODE = 'check_violation';
        END IF;

        IF checked_transfer.status = 'failed' AND entry_count <> 0 THEN
          RAISE EXCEPTION 'failed transfer % must not have ledger entries', checked_transfer_id
            USING ERRCODE = 'check_violation';
        END IF;
      END;
      $$;

      CREATE FUNCTION check_transfer_row_ledger() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM assert_transfer_ledger(NEW.id);
        RETURN NULL;
      END;
      $$;

      CREATE FUNCTION check_ledger_row_transfer() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.transfer_id IS NOT NULL THEN
          PERFORM assert_transfer_ledger(NEW.transfer_id);
        END IF;
        RETURN NULL;
      END;
      $$;

      CREATE CONSTRAINT TRIGGER transfers_ledger_consistent
      AFTER INSERT OR UPDATE ON transfers
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION check_transfer_row_ledger();

      CREATE CONSTRAINT TRIGGER ledger_entries_transfer_consistent
      AFTER INSERT ON ledger_entries
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION check_ledger_row_transfer();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS ledger_entries_transfer_consistent ON ledger_entries;
      DROP TRIGGER IF EXISTS transfers_ledger_consistent ON transfers;
      DROP TRIGGER IF EXISTS transfers_immutable_identity_and_status ON transfers;
      DROP TRIGGER IF EXISTS ledger_entries_append_only ON ledger_entries;
      DROP FUNCTION IF EXISTS check_ledger_row_transfer();
      DROP FUNCTION IF EXISTS check_transfer_row_ledger();
      DROP FUNCTION IF EXISTS assert_transfer_ledger(bigint);
      DROP FUNCTION IF EXISTS forbid_transfer_identity_mutation();
      DROP FUNCTION IF EXISTS forbid_ledger_mutation();
    SQL
  end
end

