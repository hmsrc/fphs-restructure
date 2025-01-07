require 'active_support/concern'
require 'simple_token_authentication/token_authenticatable'

module SimpleTokenAuthentication
  module ActsAsTokenAuthenticatable

    extend ActiveSupport::Concern

    # This module ensures that no TokenAuthenticatableHandler behaviour
    # is added before the class actually `acts_as_token_authenticatable`
    # otherwise we inject unnecessary methods into ORMs.
    # This follows the pattern of ActsAsTokenAuthenticationHandler
    included do
      private :generate_authentication_token
      private :token_suitable?
      private :token_generator
    end

    # Set an authentication token if missing
    #
    # Because it is intended to be used as a filter,
    # this method is -and should be kept- idempotent.
    def ensure_authentication_token
      if authentication_token.blank?
        self.authentication_token = generate_authentication_token(token_generator)
      end
    end

    def generate_authentication_token(token_generator)
      loop do
        token = token_generator.generate_token
        break token if token_suitable?(token)
      end
    end

    def token_suitable?(token)
      self.class.unscoped.where(authentication_token: token).count == 0
    end

    def token_generator
      TokenGenerator.instance
    end

    module ClassMethods
      def acts_as_token_authenticatable(options = {})
        include SimpleTokenAuthentication::TokenAuthenticatable
      end
    end
  end
end
