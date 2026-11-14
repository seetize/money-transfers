SELECT a.*
FROM accounts AS a
WHERE NOT EXISTS (
  SELECT 1
  FROM ledger_entries AS le
  WHERE le.account_id = a.id
    AND le.created_at >= CURRENT_TIMESTAMP - INTERVAL '90 days'
)
ORDER BY a.id;

