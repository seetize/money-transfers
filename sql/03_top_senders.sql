SELECT a.user_id, SUM(t.amount) AS total_outgoing
FROM transfers AS t
JOIN accounts AS a ON a.id = t.from_account_id
WHERE t.status = 'completed'
  AND t.created_at >= CURRENT_TIMESTAMP - INTERVAL '30 days'
GROUP BY a.user_id
ORDER BY total_outgoing DESC, a.user_id ASC
LIMIT 5;

