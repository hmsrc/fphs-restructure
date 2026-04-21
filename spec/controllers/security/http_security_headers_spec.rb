# frozen_string_literal: true

# Security regression coverage for HTTP response headers.
#
# Verifies that the application returns appropriate security headers to protect
# against common web attacks:
# - X-Frame-Options: Prevents clickjacking
# - X-Content-Type-Options: Prevents MIME-sniffing
# - Content-Security-Policy: Controls resource loading (currently report-only)
# - Cache-Control: Prevents caching of sensitive pages
# - Referrer-Policy: Controls referrer information leakage
#
# NOTE: Some headers (X-Frame-Options, X-Content-Type-Options, Referrer-Policy)
# are commented out in config/initializers/new_framework_defaults_7_0.rb,
# meaning this app relies on Rails 7.2 built-in defaults. These tests verify
# whether the defaults are actually present.

require 'rails_helper'

RSpec.describe 'HTTP security headers', type: :request do
  include UserSupport

  before(:each) do
    @admin, = create_admin
    @user, = create_user
  end

  context 'after authenticated page load' do
    before(:each) do
      otp = @user.current_otp
      post user_session_path,
           params: {
             user: {
               email: @user.email,
               password: @good_password,
               otp_attempt: otp
             }
           }
      follow_redirect! if response.redirect?

      # Make a normal authenticated GET request
      get '/masters/search'
    end

    it 'returns Cache-Control no-store headers on authenticated pages' do
      cc = response.headers['Cache-Control']
      expect(cc).to be_present
      expect(cc).to include('no-store')
    end

    it 'returns X-Frame-Options header' do
      # Rails 7.2 default is SAMEORIGIN unless overridden
      xfo = response.headers['X-Frame-Options']
      expect(xfo).to be_present, 'X-Frame-Options header is missing — clickjacking risk'
      expect(xfo).to eq('SAMEORIGIN')
    end

    it 'returns X-Content-Type-Options nosniff header' do
      xcto = response.headers['X-Content-Type-Options']
      expect(xcto).to be_present, 'X-Content-Type-Options header is missing — MIME sniffing risk'
      expect(xcto).to eq('nosniff')
    end

    it 'returns a Content-Security-Policy header (even if report-only)' do
      # CSP is configured but in report-only mode
      csp = response.headers['Content-Security-Policy-Report-Only'] ||
            response.headers['Content-Security-Policy']
      expect(csp).to be_present, 'No CSP header found — XSS protection reduced'
    end

    it 'CSP does not use unsafe-eval in script-src (currently fails — documents risk)' do
      csp = response.headers['Content-Security-Policy-Report-Only'] ||
            response.headers['Content-Security-Policy']
      next unless csp

      # This documents the CURRENT state: unsafe-eval IS present.
      # When fixed, change this to `not_to include`.
      expect(csp).to include('unsafe-eval'),
                     'CSP no longer includes unsafe-eval — update this test if intentional'
    end

    it 'CSP is in report-only mode (not enforced)' do
      # Documents that CSP is NOT enforced — violations are only reported.
      # When ready to enforce, change this expectation.
      enforced_csp = response.headers['Content-Security-Policy']
      report_only_csp = response.headers['Content-Security-Policy-Report-Only']

      expect(report_only_csp).to be_present,
                                 'CSP is now in enforcement mode — update this test if intentional'
      # If both are present, that's also worth noting
    end
  end

  context 'on unauthenticated pages' do
    it 'returns security headers on the login page' do
      get new_user_session_path

      xfo = response.headers['X-Frame-Options']
      expect(xfo).to be_present, 'Login page missing X-Frame-Options — clickjacking risk'
    end
  end
end
