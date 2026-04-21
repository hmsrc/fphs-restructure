# frozen_string_literal: true

# Security regression coverage for editable report authorization.
#
# This example intentionally documents current vulnerable behavior: the
# ReportsController edit path checks only whether a report is editable,
# but does not enforce either report-level access or the edit_report_data
# capability before loading the underlying record and rendering the edit form.

require 'rails_helper'

RSpec.describe ReportsController, type: :controller do
  include ItemFlagSupport

  before(:each) do
    @admin, = create_admin
    @request.env['devise.mapping'] = Devise.mappings[:user]

    @user, = create_user
    sign_in @user

    create_item
    @runner_hash = SecureRandom.hex(12)
    Rails.cache.write("runner_hash-#{@runner_hash}", %w[id disabled])

    setup_access :item_flags, access: :update, user: @user
    setup_access :edit_report_data, resource_type: :general, access: nil, user: @user

    @editable_report = Report.create!(
      current_admin: @admin,
      name: "Editable Security Report #{SecureRandom.hex(6)}",
      description: '',
      sql: 'select id, disabled from item_flags',
      search_attrs: '',
      disabled: false,
      report_type: 'regular_report',
      auto: false,
      searchable: false,
      position: nil,
      edit_model: 'item_flags',
      edit_field_names: 'disabled',
      selection_fields: nil,
      item_type: 'type-1'
    )

    setup_access @editable_report.alt_resource_name, resource_type: :report, access: nil, user: @user
    @user.clear_has_access_to!
  end

  it 'renders the editable report form without report read access or edit_report_data capability' do
    expect(@user.has_access_to?(:read, :report, @editable_report.alt_resource_name)).to be_nil
    expect(@user.can?(:edit_report_data)).to be_nil

    get :edit,
          params: {
            report_id: @editable_report.id,
            id: @item_flag.id,
            runner_hash: @runner_hash
          },
          format: :js

    expect(response).not_to have_http_status(:unauthorized)
    expect(assigns(:report_item)&.id).to eq(@item_flag.id)
  end
end