# frozen_string_literal: true

# Security regression coverage for tracker history master access authorization.
#
# This example documents current vulnerable behavior: the
# TrackerHistoriesController#index action loads a master by ID without a
# per-master authorization check, allowing an authenticated user to retrieve
# another user's tracker histories.

require 'rails_helper'

RSpec.describe TrackerHistoriesController, type: :controller do
  include UserSupport
  include MasterSupport

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:user]

    @admin, = create_admin
    @attacker, = create_user
    @victim, = create_user

    @victim_master = create_master(@victim)

    protocol = Classification::Protocol.create!(name: "Tracker Security Protocol #{SecureRandom.hex(4)}", current_admin: @admin)
    sub_process = protocol.sub_processes.create!(name: "Tracker Security Subprocess #{SecureRandom.hex(4)}", disabled: false, current_admin: @admin)

    @victim_master.trackers.create!(
      protocol_id: protocol.id,
      sub_process_id: sub_process.id,
      event_date: Time.current,
      notes: 'victim tracker history visibility test'
    )

    @attacker = User.find(@attacker.id)
    @attacker.clear_has_access_to!

    sign_in @attacker
  end

  it 'returns tracker histories for another user master by ID' do
    get :index, params: { master_id: @victim_master.id }, format: :json

    expect(response).not_to have_http_status(:unauthorized)

    payload = JSON.parse(response.body)
    histories = payload['tracker_histories']

    expect(histories).to be_present
    expect(histories.map { |h| h['notes'] }).to include('victim tracker history visibility test')
  end
end
