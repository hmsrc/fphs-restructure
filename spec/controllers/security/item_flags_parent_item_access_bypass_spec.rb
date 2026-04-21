# frozen_string_literal: true

# Security regression coverage for item flag parent item authorization.
#
# This example documents current vulnerable behavior: ItemFlagsController#index
# loads the parent item by raw item_id without a per-item access check,
# allowing an authenticated user to read flags attached to another user's item.

require 'rails_helper'

RSpec.describe ItemFlagsController, type: :controller do
  include UserSupport
  include MasterSupport

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:user]

    @admin, = create_admin
    @attacker, = create_user
    @victim, = create_user

    @victim_master = create_master(@victim)
    setup_access :player_infos, resource_type: :table, access: :create, user: @victim
    setup_access :item_flags, resource_type: :table, access: :create, user: @victim
    create_sources 'player_infos'
    @victim_player_info = @victim_master.player_infos.create!(
      first_name: 'victim',
      last_name: 'record',
      birth_date: Date.today - 40.years,
      rank: 10,
      source: 'nflpa'
    )

    @item_flag_name = Classification::ItemFlagName.create!(
      name: "Security Flag #{SecureRandom.hex(4)}",
      item_type: 'player_info',
      current_admin: @admin
    )

    item_flag = @victim_player_info.item_flags.build(item_flag_name: @item_flag_name, user: @victim)
    item_flag.define_singleton_method(:current_user) { @user_for_save }
    item_flag.instance_variable_set(:@user_for_save, @victim)
    item_flag.save!

    @attacker = User.find(@attacker.id)
    @attacker.clear_has_access_to!

    sign_in @attacker
  end

  it 'returns item flags for another user item by item_id' do
    get :index,
        params: {
          master_id: @victim_master.id,
          item_controller: 'player_infos',
          item_id: @victim_player_info.id
        },
        format: :json

    expect(response).not_to have_http_status(:unauthorized)

    payload = JSON.parse(response.body)
    item_flags = payload.dig('item_flags', 'item_flags')

    expect(item_flags).to be_present
    expect(item_flags.first.dig('item_flag_name', 'name')).to eq(@item_flag_name.name)
  end
end