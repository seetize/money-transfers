class TransferMoney
  class Error < StandardError; end
  class InvalidAmount < Error; end
  class InvalidAccount < Error; end
  class SameAccount < Error; end
  class AccountNotFound < Error; end
  class InvalidIdempotencyKey < Error; end
  class IdempotencyConflict < Error; end

  RETRYABLE_ERRORS = [
    ActiveRecord::Deadlocked,
    ActiveRecord::SerializationFailure,
    ActiveRecord::LockWaitTimeout
  ].freeze
  MAX_ATTEMPTS = 3
  MAX_AMOUNT = BigDecimal("9999999999999999.99")

  def self.call(**arguments)
    new(**arguments).call
  end

  def initialize(from_account_id:, to_account_id:, amount:, idempotency_key:)
    @from_account_id = parse_account_id(from_account_id)
    @to_account_id = parse_account_id(to_account_id)
    @amount = parse_amount(amount)
    @idempotency_key = idempotency_key.to_s
  end

  # Do not call inside an application-owned transaction: retryable PostgreSQL errors
  # abort the surrounding transaction and must be retried from its outermost boundary.
  def call
    validate!
    with_retries { perform }
  end

  private

  def parse_account_id(value)
    Integer(value)
  rescue ArgumentError, TypeError
    raise InvalidAccount, "account id must be an integer"
  end

  def parse_amount(value)
    raise InvalidAmount, "Float is not allowed for money" if value.is_a?(Float)

    BigDecimal(value.to_s)
  rescue ArgumentError
    raise InvalidAmount, "amount must be a decimal number"
  end

  def validate!
    raise InvalidAccount, "account id must be positive" if @from_account_id <= 0 || @to_account_id <= 0
    raise SameAccount, "sender and receiver must differ" if @from_account_id == @to_account_id
    raise InvalidAmount, "amount must be finite and positive" unless @amount.finite? && @amount.positive?
    raise InvalidAmount, "amount has more than 2 decimal places" unless @amount == @amount.round(2)
    raise InvalidAmount, "amount exceeds NUMERIC(18,2)" if @amount > MAX_AMOUNT
    raise InvalidIdempotencyKey, "idempotency_key is required" if @idempotency_key.empty?
    raise InvalidIdempotencyKey, "idempotency_key is too long" if @idempotency_key.length > 255
  end

  def perform
    Transfer.transaction do
      Transfer.connection.execute("SET LOCAL lock_timeout = '3s'")

      transfer_id = claim_idempotency_key
      next replay unless transfer_id

      accounts = lock_accounts
      transfer = Transfer.find(transfer_id)

      if accounts.fetch(@from_account_id).balance < @amount
        transfer.update!(status: "failed", failure_reason: "insufficient_funds")
        transfer.replayed_request = false
        next transfer
      end

      update_balances!
      create_ledger_entries!(transfer.id)
      transfer.update!(status: "completed")
      transfer.replayed_request = false
      transfer
    end
  rescue ActiveRecord::InvalidForeignKey
    raise AccountNotFound, "account does not exist"
  end

  def claim_idempotency_key
    result = Transfer.insert_all(
      [{
        from_account_id: @from_account_id,
        to_account_id: @to_account_id,
        amount: @amount,
        status: "pending",
        idempotency_key: @idempotency_key,
        created_at: Time.current,
        updated_at: Time.current
      }],
      unique_by: :index_transfers_on_idempotency_key,
      returning: %w[id]
    )
    result.rows.dig(0, 0)
  end

  def replay
    existing = Transfer.find_by!(idempotency_key: @idempotency_key)
    same_request = existing.from_account_id == @from_account_id &&
      existing.to_account_id == @to_account_id &&
      existing.amount == @amount
    raise IdempotencyConflict, "key was already used with different parameters" unless same_request

    existing.replayed_request = true
    existing
  end

  def lock_accounts
    accounts = Account.where(id: [@from_account_id, @to_account_id])
      .order(:id)
      .lock("FOR NO KEY UPDATE")
      .index_by(&:id)
    raise AccountNotFound, "account does not exist" unless accounts.size == 2

    accounts
  end

  def update_balances!
    Account.where(id: @from_account_id)
      .update_all(["balance = balance - ?, updated_at = CURRENT_TIMESTAMP", @amount])
    Account.where(id: @to_account_id)
      .update_all(["balance = balance + ?, updated_at = CURRENT_TIMESTAMP", @amount])
  end

  def create_ledger_entries!(transfer_id)
    timestamp = Time.current
    LedgerEntry.insert_all!([
      {
        transfer_id: transfer_id,
        account_id: @from_account_id,
        amount: -@amount,
        kind: "transfer",
        created_at: timestamp
      },
      {
        transfer_id: transfer_id,
        account_id: @to_account_id,
        amount: @amount,
        kind: "transfer",
        created_at: timestamp
      }
    ])
  end

  def with_retries
    attempts = 0

    begin
      attempts += 1
      yield
    rescue *RETRYABLE_ERRORS
      raise if attempts >= MAX_ATTEMPTS

      sleep((0.02 * (2**(attempts - 1))) + rand(0.0..0.02))
      retry
    end
  end
end

