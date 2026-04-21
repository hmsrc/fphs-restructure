# frozen_string_literal: true

# Security regression coverage for activity log parent item authorization.
#
# This example documents current vulnerable behavior: the
# ActivityLog::PlayerContactPhonesController#index action loads the parent item
# by raw item_id without a per-item access check, allowing a user with access
# to the activity-log resource to read another user's logs.

require 'rails_helper'

RSpec.describe ActivityLog::PlayerContactPhonesController, type: :controller do
  include UserSupport
  include MasterSupport
  include ActivityLogSupport

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:user]

    @admin, = create_admin
    @attacker, = create_user
    @victim, = create_user

    @user = @victim
    create_master(@victim)
    create_sources 'player_contacts'

    @activity_log_master = @master
    @activity_log_master.current_user = @victim

    @player_contact = @activity_log_master.player_contacts.create!(
      data: '(555) 111-2222',
      source: 'nfl',
      rank: 10,
      rec_type: 'phone'
    )

    setup_access :activity_log__player_contact_phones, user: @victim
    setup_access :activity_log__player_contact_phone__primary, resource_type: :activity_log_type, user: @victim

    @activity_log = @player_contact.activity_log__player_contact_phones.create!(
      player_contact_id: @player_contact.id,
      select_call_direction: 'to player',
      select_who: 'user',
      extra_log_type: 'primary',
      master: @activity_log_master
    )

    setup_access :activity_log__player_contact_phones, user: @attacker
    setup_access :activity_log__player_contact_phone__primary, resource_type: :activity_log_type, user: @attacker

    sign_in @attacker
  end

  it 'returns logs for another user item when caller only has activity-log access' do
    get :index,
        params: {
          master_id: @activity_log_master.id,
          item_id: @player_contact.id
        },
        format: :json

    expect(response).not_to have_http_status(:unauthorized)

    payload = JSON.parse(response.body)
    logs = payload['activity_log__player_contact_phones']

    expect(logs).to be_present
    expect(logs.first['id']).to eq(@activity_log.id)
  end
end