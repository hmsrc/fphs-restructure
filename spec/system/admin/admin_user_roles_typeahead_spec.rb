# frozen_string_literal: true

require 'rails_helper'

# System tests for admin user roles typeahead field - Issue #1120
#
# Tests the typeahead functionality on the role_name field in the new user role admin form.
# When an admin adds a new user role, the role_name field should be a text input (not a select
# dropdown) with typeahead suggestions populated from existing active role names via
# GET /definitions/user_roles.
#
# The typeahead is initialized by _fpa_admin.user_roles.admin_edit_form.setup_role_name()
# when the new role form loads, wrapping the input with a .twitter-typeahead container.
describe 'admin user roles typeahead', js: true, driver: $browser_driver do
  include ModelSupport
  include AdminActionsSetup
  include FeatureSupport

  before(:all) do
    SetupHelper.feature_setup

    @app_type_1 = Admin::AppType.active.first || Admin::AppType.create!(
      name: 'test_app_typeahead',
      label: 'Test App Typeahead',
      current_admin: Admin.first
    )
  end

  before(:each) do
    make_an_admin
    login_as(@admin, scope: :admin)

    # Create a test user to associate roles with
    @test_user, = create_user(email: "typeahead_user_#{rand(1_000_000_000)}@testing.com")

    # Create existing roles so the typeahead has suggestions to offer
    @existing_role_names = ['researcher_role', 'coordinator_role', 'data_entry_role']
    @existing_role_names.each do |role_name|
      Admin::UserRole.create!(
        user: @test_user,
        app_type: @app_type_1,
        role_name: role_name,
        current_admin: @admin
      )
    end

    Rails.cache.clear
  end

  # Helper: navigate to user roles admin and open the new role form via AJAX
  def open_new_user_role_form
    visit admin_user_roles_path
    finish_page_loading

    # The "new" add-item-button appears twice (in status bar and index actions).
    # Click the first visible one to load the new role form via AJAX.
    new_btn = all('a.add-item-button').first
    scroll_into_view(new_btn)
    new_btn.click
    finish_page_loading
    finish_form_formatting
  end

  it 'displays the role_name field as a text input in the new user role form' do
    open_new_user_role_form

    # The role_name field must be a text input, not a select dropdown
    expect(page).to have_css('input#admin_user_role_role_name[type="text"]', wait: 10)
    expect(page).not_to have_css('select#admin_user_role_role_name')
  end

  it 'wraps the role_name input with the twitter-typeahead container after initialization' do
    open_new_user_role_form

    # The JS setup_role_name() method initializes the typeahead, which wraps the
    # input element inside a .twitter-typeahead span
    expect(page).to have_css('.twitter-typeahead', wait: 10)
    expect(page).to have_css('.twitter-typeahead input#admin_user_role_role_name', wait: 10)
  end

  it 'shows typeahead suggestions when typing an existing role name prefix' do
    open_new_user_role_form

    expect(page).to have_css('input#admin_user_role_role_name', wait: 10)

    # Type a prefix that matches one of the existing role names
    find('#admin_user_role_role_name').set('researcher')

    # Typeahead suggestions should appear in the dropdown
    expect(page).to have_css('.tt-suggestion.tt-selectable', wait: 10)
    expect(page).to have_css('.tt-suggestion', text: 'researcher_role', wait: 10)
  end

  it 'populates the role_name field when clicking a typeahead suggestion' do
    open_new_user_role_form

    expect(page).to have_css('input#admin_user_role_role_name', wait: 10)

    # Type a prefix and wait for suggestions
    find('#admin_user_role_role_name').set('researcher')
    expect(page).to have_css('.tt-suggestion', text: 'researcher_role', wait: 10)

    # Click the suggestion
    find('.tt-suggestion', text: 'researcher_role').click

    # The input should now contain the full role name from the suggestion
    expect(find('#admin_user_role_role_name').value).to eq 'researcher_role'
  end

  it 'does not show disabled role names as typeahead suggestions' do
    # Create a disabled role that should not appear in suggestions
    disabled_role_name = 'disabled_secret_role'
    Admin::UserRole.create!(
      user: @test_user,
      app_type: @app_type_1,
      role_name: disabled_role_name,
      current_admin: @admin
    )
    # Disable ALL roles with this name (including template user copies from save_template callback)
    Admin::UserRole.where(role_name: disabled_role_name, app_type_id: @app_type_1.id).update_all(disabled: true)
    Rails.cache.clear

    open_new_user_role_form

    expect(page).to have_css('input#admin_user_role_role_name', wait: 10)

    # Type the disabled role prefix
    find('#admin_user_role_role_name').set('disabled_secret')

    # The disabled role name should not appear in the typeahead suggestions
    sleep 1 # allow typeahead debounce
    expect(page).not_to have_css('.tt-suggestion', text: disabled_role_name)
  end
end
