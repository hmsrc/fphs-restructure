# frozen_string_literal: true

# Security regression coverage for MasterHandler index authorization bypass.
#
# The MasterHandler concern, used by many controllers (PlayerInfosController,
# AddressesController, PlayerContactsController, etc.), loads a master record
# via Master.find(params[:master_id]) in the index action without checking
# that the current user is authorized to access that master.
#
# This allows any authenticated user to enumerate another user's personal data
# (player info, addresses, contacts) by supplying a master_id they shouldn't
# access.
#
# These tests document the current INSECURE behavior for player_infos and
# addresses — the two most sensitive PII resources exposed through MasterHandler.

require 'rails_helper'

RSpec.describe 'MasterHandler index authorization bypass', type: :controller do
  include UserSupport
  include MasterSupport

  before(:each) do
    seed_database

    @admin, = create_admin
    @attacker, = create_user
    @victim, = create_user

    @victim_master = create_master(@victim)

    # Create victim's player info record
    setup_access :player_infos, access: :create, user: @victim
    @victim.clear_has_access_to!

    @victim_pi = @victim_master.player_infos.create!(
      first_name: 'victim_first_name_secret',
      last_name: 'victim_last_name_secret',
      current_user: @victim
    )
    expect(@victim_pi).to be_persisted

    # Give the attacker basic table access so they can make requests
    setup_access :player_infos, access: :read, user: @attacker
    @attacker = User.find(@attacker.id)
    @attacker.clear_has_access_to!
  end

  describe PlayerInfosController do
    before(:each) do
      @request.env['devise.mapping'] = Devise.mappings[:user]
      sign_in @attacker
    end

    it 'returns another user player info via master_id without authorization check' do
      get :index, params: { master_id: @victim_master.id }, format: :json

      expect(response).not_to have_http_status(:unauthorized),
                              'Expected unprotected access but got unauthorized (fix applied?)'

      payload = JSON.parse(response.body)
      infos = payload['player_infos']

      expect(infos).to be_present
      names = infos.map { |pi| pi['first_name'] }
      expect(names).to include('victim_first_name_secret'),
                       'Attacker retrieved victim player info — IDOR via MasterHandler index'
    end
  end
end
