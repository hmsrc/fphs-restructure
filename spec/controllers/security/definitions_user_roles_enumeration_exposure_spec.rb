# frozen_string_literal: true

# Security regression coverage for definitions role enumeration exposure.
#
# This example documents current vulnerable behavior: the DefinitionsController
# exposes active role names through /definitions/user_roles to any authenticated
# user, without requiring a dedicated administrative capability.

require 'rails_helper'

RSpec.describe DefinitionsController, type: :controller do
  include UserSupport

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:user]

    @requesting_user, = create_user
    @role_user, = create_user

    Admin::UserRole.create!(
      current_admin: @admin,
      user: @role_user,
      app_type: @role_user.app_type,
      role_name: "security-role-#{SecureRandom.hex(4)}"
    )

    @requesting_user = User.find(@requesting_user.id)
    @requesting_user.clear_has_access_to!

    sign_in @requesting_user
  end

  it 'returns active role names to a user without privileged access' do
    get :show, params: { id: 'user_roles' }, format: :json

    expect(response).not_to have_http_status(:unauthorized)

    payload = JSON.parse(response.body)

    expect(payload).to include(@role_user.user_roles.first.role_name)
  end
end