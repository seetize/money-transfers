SELECT t.id, t.status
FROM transfers AS t
LEFT JOIN ledger_entries AS le ON le.transfer_id = t.id
GROUP BY t.id
HAVING CASE
  WHEN t.status = 'completed' THEN NOT (
    COUNT(le.id) = 2
    AND COUNT(*) FILTER (
      WHERE le.account_id = t.from_account_id AND le.amount = -t.amount
    ) = 1
    AND COUNT(*) FILTER (
      WHERE le.account_id = t.to_account_id AND le.amount = t.amount
    ) = 1
  )
  ELSE COUNT(le.id) <> 0
END
ORDER BY t.id;

