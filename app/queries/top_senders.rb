class TopSenders
  def self.call(since: 30.days.ago, limit: 5)
    Transfer
      .completed
      .where(created_at: since..)
      .joins(:from_account)
      .group("accounts.user_id")
      .order(Arel.sql("SUM(transfers.amount) DESC, accounts.user_id ASC"))
      .limit(limit)
      .sum(:amount)
  end
end

