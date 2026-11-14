SELECT t.id,
       t.status,
       COALESCE(SUM(le.amount), 0) AS ledger_net,
       COUNT(le.id) AS entries_count
FROM transfers AS t
LEFT JOIN ledger_entries AS le ON le.transfer_id = t.id
GROUP BY t.id
HAVING COALESCE(SUM(le.amount), 0) <> 0
ORDER BY t.id;

