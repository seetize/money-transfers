class InvalidTransferLedgers
  def self.call
    Transfer
      .left_joins(:ledger_entries)
      .group("transfers.id")
      .having(<<~SQL.squish)
        CASE WHEN transfers.status = 'completed' THEN NOT (
          COUNT(ledger_entries.id) = 2
          AND COUNT(*) FILTER (
            WHERE ledger_entries.account_id = transfers.from_account_id
              AND ledger_entries.amount = -transfers.amount
          ) = 1
          AND COUNT(*) FILTER (
            WHERE ledger_entries.account_id = transfers.to_account_id
              AND ledger_entries.amount = transfers.amount
          ) = 1
        ) ELSE COUNT(ledger_entries.id) <> 0 END
      SQL
  end
end
