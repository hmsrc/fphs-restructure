# frozen_string_literal: true

# Help Sidebar: "back to main section" navigation from general option pages
#
# When an admin navigates from a section-specific help page (e.g. activity_logs/detailed_options)
# into a shared general option page (e.g. general/constants), clicking "back to main section"
# should return to the originating detailed_options page — not to the general section's
# 0_introduction page.
#
# This requires a co-ordinated mechanism:
#   1. The embedded help partial emits `data-help-path` on the wrapper div so the JS
#      knows the path of the page that links were loaded from.
#   2. The help_sidebar JS postprocessor appends `back_path=<source>` to any link that
#      navigates into the shared `general` section.
#   3. HelpHelper#main_section reads and validates `params[:back_path]` to build the
#      correct "back to main section" href.
#
# Test coverage:
#   - Full AJAX sidebar flow: detailed_options → general option page → back
#   - Validates `data-help-path` is emitted and JS adds `back_path` to general links
#   - Validates "back to main section" link renders with correct target href
#   - Validates clicking back returns to the detailed_options page

require 'rails_helper'

describe 'help sidebar back link from general option pages', js: true, driver: $browser_driver do
  include AdminActionsSetup
  include FeatureSupport

  before(:all) do
    SetupHelper.feature_setup
    make_an_admin
  end

  # Open the help sidebar from the activity_logs admin page.
  # Expects the admin to already be signed in.
  # Returns once the sidebar body has received embedded content.
  def open_activity_log_help_sidebar
    visit '/admin/activity_logs'
    finish_page_loading

    # Click the ? icon which loads activity_logs/0_introduction into the sidebar
    help_icon = find('.admin-help-icon', wait: 10)
    scroll_into_view(help_icon)
    sleep 0.3
    help_icon.click

    # Sidebar should open and the introduction doc should load
    expect(page).to have_css('#help-sidebar.in', wait: 10)
    expect(page).to have_css('#help-sidebar-body', wait: 5)
    within '#help-sidebar-body' do
      expect(page).to have_content('Activity Logs', wait: 10)
    end
  end

  it 'navigates to detailed_options from the introduction' do
    admin_sign_in_with_2fa
    open_activity_log_help_sidebar

    within '#help-sidebar-body' do
      # The introduction page links to "Detailed Options"
      click_link 'Detailed Options'
      expect(page).to have_content('Activity Log: Detailed Options', wait: 10)
    end
  end

  it 'adds back_path to general links, renders correct back link, and clicking it returns to detailed_options' do
    admin_sign_in_with_2fa
    open_activity_log_help_sidebar

    within '#help-sidebar-body' do
      click_link 'Detailed Options'
      expect(page).to have_content('Activity Log: Detailed Options', wait: 10)

      # Verify JS added back_path to general links (postprocessor ran correctly)
      general_link = first('a[href*="/general/"]', wait: 10)
      href = general_link[:href]
      expect(href).to include('back_path='),
                      "Expected JS to add back_path param to general link, but href was: #{href}"
      expect(URI.decode_www_form_component(href)).to include('activity_logs/detailed_options'),
                                                     "Expected back_path to point to activity_logs/detailed_options, but href was: #{href}"

      # Navigate to the general option page
      general_link.click
      # Wait for the general section page to finish loading (data-help-path will reflect the new page)
      expect(page).to have_css('[data-help-path*="/general/"]', wait: 15)

      # "back to main section" should point back to detailed_options
      back_link = find('.help-doc-header a', text: 'back to main section', wait: 10)
      expect(back_link[:href]).to include('activity_logs/detailed_options'),
                                  "Expected 'back to main section' to point to activity_logs/detailed_options, " \
                                  "but href was: #{back_link[:href]}"

      # Clicking it should return to detailed_options
      scroll_into_view(back_link)
      sleep 0.3
      back_link.click
      # Wait for detailed_options content to reload in the sidebar
      expect(page).to have_css('[data-help-path*="/activity_logs/"]', wait: 15)
      expect(page).to have_content('Activity Log: Detailed Options', wait: 10)
    end
  end
end
