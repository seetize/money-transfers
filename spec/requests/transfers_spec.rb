require "rails_helper"

RSpec.describe "POST /transfers", type: :request do
  let(:from) { open_account(user_id: 101, deposit: BigDecimal("100")) }
  let(:to) { open_account(user_id: 102) }
  let(:key) { SecureRandom.uuid }
  let(:payload) do
    {
      transfer: {
        from_account_id: from.id,
        to_account_id: to.id,
        amount: "40.00",
        idempotency_key: key
      }
    }
  end

  it "returns 201 for the first commit and 200 for an identical replay" do
    post transfers_path, params: payload, as: :json
    transfer_id = response.parsed_body.fetch("id")

    expect(response).to have_http_status(:created)

    post transfers_path, params: payload, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("id")).to eq(transfer_id)
    expect(Transfer.count).to eq(1)
    expect(LedgerEntry.where(kind: "transfer").count).to eq(2)
  end

  it "returns 409 when the same key is reused for another request" do
    post transfers_path, params: payload, as: :json
    changed_payload = payload.deep_dup
    changed_payload[:transfer][:amount] = "41.00"

    post transfers_path, params: changed_payload, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to eq("IdempotencyConflict")
  end

  it "returns a stable failed transfer when funds are insufficient" do
    payload[:transfer][:amount] = "101.00"

    post transfers_path, params: payload, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to include(
      "status" => "failed",
      "failure_reason" => "insufficient_funds"
    )
    expect(LedgerEntry.where(kind: "transfer")).to be_empty
  end
end
