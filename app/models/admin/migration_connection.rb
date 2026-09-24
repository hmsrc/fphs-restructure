class Admin::MigrationConnection < ActiveRecord::Base
  self.abstract_class = true
  #
  # Relative path to the failed migrations directory
  def self.db_migration_failed_dirname
    'db/app_migrations/failed'
  end

  def self.dbname
    Rails.env.to_s.to_sym
  end

  def self.migration_context(name)
    Admin::MigrationGenerator.migration_context(name)
  end

  def self.migrate(db_migration_dirname, do_migration: nil)
    Timeout.timeout(Settings::MigrationTimeoutSec) do
      # Outside the current transaction
      Thread.new do
        puts "Calling migrate for #{db_migration_dirname}" unless Rails.env.production?
        call_migration_context(db_migration_dirname)
      rescue Exception => e
        FileUtils.mkdir_p db_migration_failed_dirname
        if File.exist?(do_migration)
          FileUtils.mv do_migration, db_migration_failed_dirname
          msg = "Failed migration in Thread for path '#{db_migration_dirname}' - moved '#{do_migration}' to '#{db_migration_failed_dirname}' - database #{Admin::MigrationGenerator.current_database}"
        else
          msg = "Failed migration in Thread for path '#{db_migration_dirname}' - migration file '#{do_migration}' does not exist - database #{Admin::MigrationGenerator.current_database}"
        end
        Rails.logger.warn msg
        bt = e.backtrace
              .reject { |m| m.include?('/vendor/bundle/ruby/') }
              .join("\n")
        unless Rails.env.production?
          warn msg
          warn e
          puts bt unless Rails.env.production?
        end
        raise FphsException, "#{msg}:\n#{e}\n#{bt}"
      end.join
    end

    true
  rescue Exception => e
    FileUtils.mkdir_p db_migration_failed_dirname
    if File.exist?(do_migration)
      FileUtils.mv do_migration, db_migration_failed_dirname
      msg = "Failed migration for path '#{db_migration_dirname}' - moved '#{do_migration}' to '#{db_migration_failed_dirname}' - database #{Admin::MigrationGenerator.current_database}"
    else
      msg = "Failed migration for path '#{db_migration_dirname}' - not existing '#{do_migration}' - database #{Admin::MigrationGenerator.current_database}"
    end
    Rails.logger.warn msg
    bt = e.backtrace
          .reject { |m| m.include?('/vendor/bundle/ruby/') }
          .join("\n")
    unless Rails.env.production?
      warn msg
      warn e
      puts bt unless Rails.env.production?
    end
    raise FphsException, "#{msg}:\n#{e}\n#{bt}"
  end

  def self.call_migration_context(db_migration_dirname)
    # # Establish a connection - use this approach to avoid Rails fixtures
    # establish_connection(dbname)
    ExceptionExtensions.puts_or_tmp_log 'Entering connection pool'
    ActiveRecord::Base.connection_pool.with_connection do
      puts "Running migrations on #{db_migration_dirname} in #{dbname} database"
      ctx = migration_context(db_migration_dirname)
      ExceptionExtensions.puts_or_tmp_log "Migration context: #{ctx}"
      ctx.migrate
    end
  end
end
