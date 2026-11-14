class DormantAccounts
  def self.call(since: 90.days.ago)
    recent_account_ids = LedgerEntry.where(created_at: since..).select(:account_id)
    Account.where.not(id: recent_account_ids)
  end
end

