# frozen_string_literal: true

# Security regression coverage for model reference parent item authorization.
#
# This example documents current vulnerable behavior: ModelReferencesController#edit
# loads the parent record and model reference by raw IDs without a per-item access
# check, allowing an authenticated user to open the remove-link form for another
# user's reference.

require 'rails_helper'

RSpec.describe ModelReferencesController, type: :controller do
  include UserSupport
  include MasterSupport
  include PlayerContactSupport

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:user]

    @admin, = create_admin
    @attacker, = create_user
    @victim, = create_user

    @victim_master = create_master(@victim)
    @victim_player_contact = create_item(nil, @victim_master)
    @model_reference = ModelReference.create_from_master_with(@victim_master, @victim_player_contact)

    @attacker = User.find(@attacker.id)
    @attacker.clear_has_access_to!

    sign_in @attacker
  end

  it 'renders edit for another user model reference by raw ids' do
    get :edit,
        params: {
          master_id: @victim_master.id,
          item_controller: 'masters',
          item_id: @victim_master.id,
          id: @model_reference.id
        },
        format: :js

    expect(response).not_to have_http_status(:unauthorized)
    expect(assigns(:model_reference)&.id).to eq(@model_reference.id)
  end
end