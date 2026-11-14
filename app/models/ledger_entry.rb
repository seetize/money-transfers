class LedgerEntry < ApplicationRecord
  belongs_to :transfer, optional: true
  belongs_to :account

  enum :kind, { transfer: "transfer", deposit: "deposit" }, prefix: true, validate: true

  validates :amount, numericality: { other_than: 0 }
  validate :kind_matches_transfer

  private

  def kind_matches_transfer
    return if kind_transfer? == transfer_id.present?

    errors.add(:kind, "must be transfer exactly when transfer_id is present")
  end
end

