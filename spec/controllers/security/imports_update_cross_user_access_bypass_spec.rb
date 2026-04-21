# frozen_string_literal: true

# Security regression coverage for imports ownership authorization on update.
#
# This example documents current vulnerable behavior: a user with import_csv
# capability can submit updates against another user's import by ID through
# Imports::ImportsController#update.

require 'rails_helper'

RSpec.describe Imports::ImportsController, type: :controller do
  include UserSupport

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:user]

    @attacker, = create_user
    @victim, = create_user

    setup_access :import_csv, resource_type: :general, access: :read, user: @attacker
    @attacker = User.find(@attacker.id)
    @attacker.clear_has_access_to!

    @victim_import = Imports::Import.setup_import('masters', @victim, 'victim-import.csv')
    expect(@victim_import).to be_persisted

    sign_in @attacker
  end

  it 'processes update for another user import record when requester has import_csv capability' do
    patch :update,
          params: {
            id: @victim_import.id,
            invalid_items: 0,
            imports_import: {
              primary_table: 'masters',
              masters_attributes: {
                '0' => {}
              }
            }
          }

    expect(response).not_to have_http_status(:unauthorized)
    expect(assigns(:import)&.id).to eq(@victim_import.id)
    expect(assigns(:import)&.user_id).to eq(@victim.id)
  end
end
