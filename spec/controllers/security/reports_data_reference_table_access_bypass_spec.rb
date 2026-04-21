# frozen_string_literal: true

# Security regression coverage for report data-reference table authorization.
#
# This example intentionally documents current vulnerable behavior: a user with
# broad view_data_reference capability and report access can choose arbitrary
# table_name and schema_name parameters for a report that uses
# {{schema_name}}.{{table_name}} substitutions, without per-table access checks.

require 'rails_helper'

RSpec.describe ReportsController, type: :controller do
  include UserSupport
  include ItemFlagSupport

  before(:each) do
    @admin, = create_admin

    @request.env['devise.mapping'] = Devise.mappings[:user]
    @user, = create_user
    create_item

    setup_access :view_data_reference, resource_type: :general, access: :read, user: @user
    setup_access :view_reports, resource_type: :general, access: :read, user: @user
    setup_access :item_flags, resource_type: :table, access: nil, user: @user

    @report = Report.create!(
      current_admin: @admin,
      name: "Data Reference Security Report #{SecureRandom.hex(6)}",
      description: '',
      sql: 'select id, item_type from {{schema_name}}.{{table_name}} order by id asc limit 1',
      search_attrs: '',
      disabled: false,
      report_type: 'regular_report',
      auto: false,
      searchable: true,
      position: nil,
      edit_model: nil,
      edit_field_names: nil,
      selection_fields: nil,
      item_type: 'type-1'
    )

    setup_access @report.alt_resource_name, resource_type: :report, access: :read, user: @user
    @user = User.find(@user.id)
    @user.clear_has_access_to!
    sign_in @user
  end

  it 'returns rows from item_flags via data-reference parameters even when table read access is missing' do
    expect(@user.has_access_to?(:read, :table, :item_flags)).to be_nil
    expect(@user.can?(:view_data_reference)).to be_truthy
    expect(@user.can?(:view_reports)).to be_truthy
    expect(@user.has_access_to?(:read, :report, @report.alt_resource_name)).to be_truthy

    table_schema = Admin::MigrationGenerator.table_schema_hash['item_flags']
    expect(table_schema).to be_present

    get :show,
        params: {
          id: @report.id,
          table_name: 'item_flags',
          schema_name: table_schema,
          search_attrs: { run_now: '1' },
          commit: 'run'
        },
        format: :json

    expect(response).not_to have_http_status(:unauthorized)

    result_json = JSON.parse(response.body)
    result_rows = result_json['results']
    result_row = result_rows.first
    expect(result_row).to be_present
    expect(result_row['item_type']).to be_present
  end
end