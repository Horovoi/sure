class InviteCode < ApplicationRecord
  before_validation :generate_token, on: :create

  class << self
    # Atomically consumes the code: a single DELETE, so of two concurrent
    # claims only one deletes the row. Call it inside the transaction that
    # creates the user, so a failed signup rolls the claim back.
    def claim!(token)
      return false if token.blank?

      where(token: token.to_s.strip.downcase).delete_all == 1
    end

    def generate!
      create!.token
    end
  end

  private

    def generate_token
      loop do
        self.token = SecureRandom.hex(4)
        break token unless self.class.exists?(token: token)
      end
    end
end
