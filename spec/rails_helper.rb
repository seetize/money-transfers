ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../config/environment", __dir__)
abort("The Rails environment is running in production mode!") if Rails.env.production?

require "rspec/rails"
require "securerandom"
require "concurrent"

ActiveRecord::Migration.maintain_test_schema!

module AccountHelpers
  def open_account(user_id:, deposit: BigDecimal("0"), entry_created_at: Time.current)
    Account.transaction do
      account = Account.create!(user_id: user_id, balance: deposit)
      if deposit.positive?
        LedgerEntry.create!(account: account, amount: deposit, kind: "deposit", created_at: entry_created_at)
      end
      account
    end
  end

  def complete_transfer(from:, to:, amount:, key: SecureRandom.uuid, created_at: Time.current)
    Transfer.transaction do
      transfer = Transfer.create!(
        from_account: from,
        to_account: to,
        amount: amount,
        status: "pending",
        idempotency_key: key,
        created_at: created_at
      )
      LedgerEntry.create!(transfer: transfer, account: from, amount: -amount, kind: "transfer")
      LedgerEntry.create!(transfer: transfer, account: to, amount: amount, kind: "transfer")
      transfer.update!(status: "completed")
      transfer
    end
  end
end

RSpec.configure do |config|
  config.fixture_paths = [Rails.root.join("spec/fixtures")]
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
  config.include AccountHelpers
end

