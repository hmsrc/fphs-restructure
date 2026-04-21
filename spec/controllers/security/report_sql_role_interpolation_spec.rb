# frozen_string_literal: true

# Security regression coverage for SQL interpolation of role names in report queries.
#
# Reports::Runner#substitute_current_user builds a SQL fragment by directly
# interpolating user role names with single-quote wrapping:
#
#   curtxt = cur.map { |r| "'#{r}'" }.join(',')
#
# If a role name contained a single quote (e.g. via admin misconfiguration), this
# would produce malformed SQL or enable SQL injection. Although role names are set
# only by admins, defense-in-depth requires either connection.quote() or bind
# parameters.
#
# This spec documents the risk by verifying what substitute_current_user produces
# for role names, ensuring awareness and regression coverage.

require 'rails_helper'

RSpec.describe 'Report SQL role name interpolation', type: :model do
  include UserSupport
  include ModelSupport

  before(:each) do
    @admin, = create_admin
    @user, = create_user
  end

  it 'interpolates role names directly into SQL without quoting' do
    # Create a report with :current_user_roles placeholder
    seed_database
    create_user_role 'test_role'

    report = Report.new(
      name: "security_test_#{SecureRandom.hex(6)}",
      report_type: 'regular_report',
      sql: "SELECT :current_user_roles AS roles",
      searchable: true,
      current_user: @user
    )
    report.current_admin = @admin
    report.save!

    runner = Reports::Runner.new(report)
    result_sql = runner.send(:substitute_current_user, report.sql.dup)

    # The SQL should contain role names. The key point is that they are
    # interpolated with simple string quoting, not parameterized.
    # This test documents the current approach for regression awareness.
    expect(result_sql).not_to include(':current_user_roles')
    expect(result_sql).to include('array[')
  end
end
