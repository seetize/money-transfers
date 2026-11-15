class UnbalancedTransfers
  def self.call
    Transfer
      .left_joins(:ledger_entries)
      .group("transfers.id")
      .having("COALESCE(SUM(ledger_entries.amount), 0) <> 0")
      .select(<<~SQL.squish)
        transfers.*,
        COALESCE(SUM(ledger_entries.amount), 0) AS ledger_net,
        COUNT(ledger_entries.id) AS entries_count
      SQL
  end
end
