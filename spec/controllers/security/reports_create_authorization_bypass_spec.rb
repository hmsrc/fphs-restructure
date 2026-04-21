# frozen_string_literal: true

# Security regression coverage for editable report create authorization.
#
# This example intentionally documents current vulnerable behavior: the
# ReportsController#create action does not enforce report-level access checks,
# allowing a user to reach record-create processing through an editable report
# endpoint even when that user has no read access to the report resource.

require 'rails_helper'

RSpec.describe ReportsController, type: :controller do
  include UserSupport
  include MasterSupport

  before(:each) do
    @admin, = create_admin

    @request.env['devise.mapping'] = Devise.mappings[:user]
    @user, = create_user

    setup_access :player_contacts, resource_type: :table, access: :create, user: @user
    @master = create_master(@user)

    @editable_report = Report.create!(
      current_admin: @admin,
      name: "Editable Create Security Report #{SecureRandom.hex(6)}",
      description: '',
      sql: 'select id, master_id, data, rec_type from player_contacts',
      search_attrs: '',
      disabled: false,
      report_type: 'regular_report',
      auto: false,
      searchable: true,
      position: nil,
      edit_model: 'player_contacts',
      edit_field_names: 'master_id,data,rec_type,rank,source',
      selection_fields: nil,
      item_type: 'type-1'
    )

    setup_access @editable_report.alt_resource_name, resource_type: :report, access: nil, user: @user

    @user = User.find(@user.id)
    @user.clear_has_access_to!
    sign_in @user
  end

  it 'processes editable report create without report read access' do
    expect(@user.has_access_to?(:read, :report, @editable_report.alt_resource_name)).to be_nil

    post :create,
         params: {
           report_id: @editable_report.id,
           player_contact: {
             master_id: @master.id,
             rec_type: 'phone',
             data: '(555) 111-2222',
             rank: 1,
             source: 'security-spec'
           }
         },
         format: :json

    expect(response).not_to have_http_status(:unauthorized)
    expect(assigns(:report_item)).to be_present
  end
end