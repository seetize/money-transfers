class Account < ApplicationRecord
  has_many :outgoing_transfers,
    class_name: "Transfer",
    foreign_key: :from_account_id,
    inverse_of: :from_account,
    dependent: :restrict_with_exception
  has_many :incoming_transfers,
    class_name: "Transfer",
    foreign_key: :to_account_id,
    inverse_of: :to_account,
    dependent: :restrict_with_exception
  has_many :ledger_entries, dependent: :restrict_with_exception

  validates :user_id, presence: true
  validates :balance, numericality: { greater_than_or_equal_to: 0 }
end
