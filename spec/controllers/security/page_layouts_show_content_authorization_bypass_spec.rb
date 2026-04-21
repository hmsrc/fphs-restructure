# frozen_string_literal: true

# Security regression coverage for standalone page authorization.
#
# These examples intentionally document current vulnerable behavior: the
# show_content action only checks the broad view_pages capability and skips the
# per-page access check that the show action applies.

require 'rails_helper'

RSpec.describe PageLayoutsController, type: :controller do
  include UserSupport

  render_views

  before(:all) do
    @admin, = create_admin
  end

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:user]

    @user, = create_user
    sign_in @user

    setup_access :view_pages, resource_type: :general, access: :read, user: @user

    @restricted_page = Admin::PageLayout.create!(
      layout_name: 'standalone',
      panel_name: "security-restricted-#{SecureRandom.hex(6)}",
      panel_label: 'Restricted Security Page',
      panel_position: 0,
      app_type: @user.app_type,
      current_admin: @admin,
      options: <<~YAML
        container:
          rows:
            - cols:
                - label: Restricted content
                  header: |
                    This content should require page-specific access.
      YAML
    )
  end

  it 'blocks show when the user lacks standalone page access' do
    get :show, params: { id: @restricted_page.panel_name }, format: :text

    expect(response).to have_http_status(:unauthorized)
  end

  it 'processes show_content past authorization for the same page without standalone page access' do
    get :show_content,
        params: { id: @restricted_page.panel_name, master_id: 0, secondary_key: 'none' },
        format: :text

    expect(response).to have_http_status(:internal_server_error)
    expect(response).not_to have_http_status(:unauthorized)
  end
end