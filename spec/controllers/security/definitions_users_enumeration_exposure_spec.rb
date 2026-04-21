# frozen_string_literal: true

# Security regression coverage for definitions user enumeration exposure.
#
# This example documents current vulnerable behavior: the DefinitionsController
# exposes the active user directory through /definitions/users to any
# authenticated user, without requiring a specific capability.

require 'rails_helper'

RSpec.describe DefinitionsController, type: :controller do
  include UserSupport

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:user]

    @requesting_user, = create_user
    @other_user, = create_user

    @requesting_user = User.find(@requesting_user.id)
    @requesting_user.clear_has_access_to!

    sign_in @requesting_user
  end

  it 'returns active users list to a user without privileged access' do
    get :show, params: { id: 'users' }, format: :json

    expect(response).not_to have_http_status(:unauthorized)

    payload = JSON.parse(response.body)
    names = payload.map { |row| row['name'] }

    expect(names).to include(@other_user.email)
  end
end
