# frozen_string_literal: true

# Ops::GithubConfig — the GitHub App this installation deploys through.
#
# ONE APP FOR THE WHOLE PRODUCT, not one per customer. A customer authorizes
# our App on their repositories and we get an `installation_id`; they never see
# these credentials and never type one. The screen a customer uses is the repo
# list, which has no credential field at all.
#
# Append-only, like Ops::SsoConfig and Ops::License: saving writes a new row and
# leaves the old one. There is no update, and the absence is the point — for a
# key that can read every connected repository, "who changed this and when" is
# the only record of it we would ever have.
#
# See GithubSettings for who decides between this and the environment.
class Ops::GithubConfig < ApplicationRecord
  PROVIDERS = %w[github].freeze

  # Public identifiers. A second provider means new keys here and a branch in
  # GithubSettings — not a migration.
  store_accessor :settings, :app_id, :app_slug

  # Two attributes and not one blob: `encrypts` works per attribute, and a blob
  # holding a secret among public fields is a blob somebody eventually logs.
  encrypts :private_key_ciphertext
  encrypts :webhook_secret_ciphertext

  belongs_to :configured_by, class_name: "User", optional: true

  validates :provider, presence: true, inclusion: {in: PROVIDERS}
  validates :app_id, presence: true
  validates :private_key_ciphertext, presence: true

  # GitHub's App id is numeric, and the field beside it in their UI is the
  # client id (`Iv1.…`). Pasting the wrong one produces a JWT that mints no
  # token, and the failure lands in a deploy rather than here — so it is caught
  # here instead.
  validates :app_id, format: {
    with: /\A\d+\z/, message: "should be the numeric App ID, not the client ID"
  }, if: :github?

  # The PEM is checked for SHAPE, not parsed. A truncated paste — the most
  # common way this goes wrong — has no footer, and telling somebody that at
  # save time beats an opaque signing error on their first push.
  validate :private_key_looks_like_a_pem

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def self.current = newest_first.first

  def github? = provider == "github"

  alias_attribute :private_key, :private_key_ciphertext
  alias_attribute :webhook_secret, :webhook_secret_ciphertext

  # install_url — where an operator sends a customer to authorize the App.
  #
  # Built from the slug rather than stored, because it is derived: a stored URL
  # is one more thing that can disagree with the App it names.
  def install_url
    return nil if app_slug.blank?

    "https://github.com/apps/#{app_slug}/installations/new"
  end

  private

  def private_key_looks_like_a_pem
    key = private_key.to_s

    return if key.blank?
    return if key.include?("-----BEGIN") && key.include?("-----END")

    errors.add(:private_key, "should be the full .pem contents, including the BEGIN and END lines")
  end
end
