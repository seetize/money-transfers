class TransfersController < ApplicationController
  rescue_from TransferMoney::InvalidAmount, TransferMoney::InvalidAccount,
    TransferMoney::InvalidIdempotencyKey, TransferMoney::SameAccount,
    with: :render_unprocessable
  rescue_from TransferMoney::AccountNotFound, with: :render_not_found
  rescue_from TransferMoney::IdempotencyConflict, with: :render_conflict
  rescue_from(*TransferMoney::RETRYABLE_ERRORS, with: :render_temporarily_unavailable)

  def create
    transfer = TransferMoney.call(**transfer_params.to_h.symbolize_keys)
    render json: transfer_payload(transfer), status: transfer.replayed_request ? :ok : response_status(transfer)
  end

  private

  def transfer_params
    params.require(:transfer).permit(:from_account_id, :to_account_id, :amount, :idempotency_key)
  end

  def response_status(transfer)
    transfer.completed? ? :created : :unprocessable_entity
  end

  def transfer_payload(transfer)
    transfer.as_json(only: %i[id from_account_id to_account_id amount status failure_reason created_at])
  end

  def render_unprocessable(error)
    render json: { error: error.class.name.demodulize, message: error.message }, status: :unprocessable_entity
  end

  def render_not_found(error)
    render json: { error: error.class.name.demodulize, message: error.message }, status: :not_found
  end

  def render_conflict(error)
    render json: { error: error.class.name.demodulize, message: error.message }, status: :conflict
  end

  def render_temporarily_unavailable(error)
    response.set_header("Retry-After", "1")
    render json: { error: error.class.name.demodulize, message: "temporarily unavailable" },
      status: :service_unavailable
  end
end

