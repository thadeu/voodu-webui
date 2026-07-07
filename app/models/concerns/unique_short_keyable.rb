# frozen_string_literal: true

# UniqueShortKeyable — generates an opaque, URL-friendly short key (random
# base62) on create, retried until unique. Backs the short handles that appear
# in URLs: Org#short_id (8 chars) and Server#key (6 chars).
#
#   include UniqueShortKeyable
#   unique_short_key :key, length: 6
#
# The DB unique index on the column is the real guard; the retry loop just
# avoids a RecordNotUnique on the astronomically rare collision. `||=` never
# overwrites a value the caller set (the key lands in URLs / bookmarks).
module UniqueShortKeyable
  extend ActiveSupport::Concern

  ALPHABET = (("0".."9").to_a + ("A".."Z").to_a + ("a".."z").to_a).freeze

  class_methods do
    def unique_short_key(column, length:)
      before_validation(on: :create) do
        self[column] ||= self.class.generate_unique_short_key(column, length)
      end
    end

    def generate_unique_short_key(column, length)
      loop do
        candidate = Array.new(length) { UniqueShortKeyable::ALPHABET.sample }.join

        break candidate unless exists?(column => candidate)
      end
    end
  end
end
