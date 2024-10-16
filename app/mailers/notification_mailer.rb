# frozen_string_literal: true

#
# Perform mailing to valid users and non-user email addresses
class NotificationMailer < ActionMailer::Base
  #
  # Send a message notification
  # Filter out any emails that are either invalid (no fully qualified domain name specified)
  # or where if there is a matching user it is not marked as disabled or "do not email".
  # Emails that do not match users are always acceptable, since we have no record of their preferences
  # and filtering must have been performed elsewhere
  # @param [Messaging::MessageNotification] notify
  # @param [Logger] logger - Rails logger
  # @return [Mail::Message]
  def send_message_notification(notify)
    Rails.logger.info "Sending email for #{notify.id}"
    messages = []

    emails = notify.recipient_emails.select do |email|
      email ||= ''
      res = email_has_fqdn(email)

      if res
        # Lookup the user email
        user = User.find_by(email: email&.downcase)

        # We can email if the email address is not a user, or
        # the user is not disabled and is not flagged "do not email"
        res = !user || (!user.disabled && !user.do_not_email)

        unless res
          msg = "send_message_notification email #{email} - " \
            "can not send disabled: #{user&.disabled} or do not email: #{user&.do_not_email}"
          Rails.logger.info msg
          messages << msg
        end

        res
      else
        msg = "send_message_notification email #{email} - " \
          'can not send due to no FQDN'
        Rails.logger.info msg
        messages << msg
      end
      res
    end

    if notify.from_user_email.blank?
      raise FphsException,
            'No FROM user set in notification. Check NotificationsFromEmail setting'
    end

    if emails.empty?
      raise FphsException,
            "No TO emails set in notification for #{notify.recipient_emails}.\n#{messages.join("\n")}"
    end

    options = {
      to: emails,
      from: notify.from_user_email,
      body: notify.generated_text,
      content_type: 'text/html',
      subject: notify.subject
    }

    logger.info "Sending email options: #{options}"
    return if Rails.env.test?

    mail(options)
  end

  #
  # Check there is at least one dot in the domain name
  # which we will consider is a valid fully qualified domain name
  # This removes '@test' and '@template'
  # @param [String] email
  # @return [Boolean]
  def email_has_fqdn(email)
    domain = email.split('@', 2)
    domain.last&.include?('.')
  end
end
