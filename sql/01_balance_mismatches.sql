SELECT a.id,
       a.balance,
       COALESCE(SUM(le.amount), 0) AS ledger_balance,
       a.balance - COALESCE(SUM(le.amount), 0) AS difference
FROM accounts AS a
LEFT JOIN ledger_entries AS le ON le.account_id = a.id
GROUP BY a.id
HAVING a.balance <> COALESCE(SUM(le.amount), 0)
ORDER BY a.id;

