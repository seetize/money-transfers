class BalanceMismatches
  def self.call
    Account
      .left_joins(:ledger_entries)
      .group("accounts.id")
      .having("accounts.balance <> COALESCE(SUM(ledger_entries.amount), 0)")
      .select(<<~SQL.squish)
        accounts.*,
        COALESCE(SUM(ledger_entries.amount), 0) AS ledger_balance,
        accounts.balance - COALESCE(SUM(ledger_entries.amount), 0) AS difference
      SQL
  end
end

