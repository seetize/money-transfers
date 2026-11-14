class Transfer < ApplicationRecord
  attr_accessor :replayed_request

  belongs_to :from_account, class_name: "Account", inverse_of: :outgoing_transfers
  belongs_to :to_account, class_name: "Account", inverse_of: :incoming_transfers
  has_many :ledger_entries, dependent: :restrict_with_exception

  enum :status, { pending: "pending", completed: "completed", failed: "failed" }, validate: true

  validates :amount, numericality: { greater_than: 0 }
  validates :idempotency_key, presence: true, uniqueness: true
  validate :accounts_must_differ

  private

  def accounts_must_differ
    errors.add(:to_account, "must differ from sender") if from_account_id == to_account_id
  end
end

