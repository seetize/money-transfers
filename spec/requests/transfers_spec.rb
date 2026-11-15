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

    expect(response.status).to eq(422)
    expect(response.parsed_body).to include(
      "status" => "failed",
      "failure_reason" => "insufficient_funds"
    )
    expect(LedgerEntry.where(kind: "transfer")).to be_empty
  end

  %i[from_account_id to_account_id amount idempotency_key].each do |field|
    it "returns 422 when #{field} is missing" do
      payload[:transfer].delete(field)
      post transfers_path, params: payload, as: :json
      expect(response.status).to eq(422)
      expect(Transfer.count).to eq(0)
    end
  end

  [ nil, "invalid", [], {}, { amount: [ "10" ] } ].each do |invalid|
    it "handles malformed transfer input #{invalid.inspect}" do
      post transfers_path, params: { transfer: invalid }, as: :json
      expect(response.status).to eq(422)
    end
  end

  it "returns 422 for a fractional sender id" do
    payload[:transfer][:from_account_id] = from.id + 0.9
    post transfers_path, params: payload, as: :json
    expect(response.status).to eq(422)
  end

  it "returns 404 for a missing account" do
    payload[:transfer][:to_account_id] = 999_999
    post transfers_path, params: payload, as: :json
    expect(response.status).to eq(404)
    expect(Transfer.count).to eq(0)
  end

  it "returns 503 and Retry-After after transient retries are exhausted" do
    allow(TransferMoney).to receive(:call).and_raise(ActiveRecord::Deadlocked)
    post transfers_path, params: payload, as: :json
    expect(response.status).to eq(503)
    expect(response.headers["Retry-After"]).to eq("1")
  end
end
