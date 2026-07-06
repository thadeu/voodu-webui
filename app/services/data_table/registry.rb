# frozen_string_literal: true

# DataTable::Registry — resolves a source key (e.g. "hep3") to a source
# object the generic Components::UI::DataTable can render.
#
# THE CONTRACT (duck-typed). A source is any object that responds to:
#
#   fields          -> [String]   every column / filterable field name
#   default_fields  -> [String]   the subset shown before the operator
#                                  customises the column picker
#   rows(filter:, limit:, before_id:, since_id:) -> [Hash]
#                                  flat rows (string-keyed); EVERY row
#                                  carries "id" — the cursor the table
#                                  uses for infinite scroll (before_id)
#                                  and live-append (since_id). `filter`
#                                  is {field:, value:} (substring) or nil.
#   live_stream     -> String | nil   ActionCable stream the source
#                                  broadcasts to when new rows land
#                                  (nil = no realtime, poll instead)
#
# The table is SCHEMA-LESS: it derives columns from `fields`, renders
# every value as text, and offers a substring filter on any field. No
# types/labels/formatting are declared — a new source just implements
# the four methods + a `from_params(server:, params:)` factory and
# registers its key below.
module DataTable
  module Registry
    # Keyed by string name → class name (string, constantized lazily so
    # this file doesn't force the source classes to load at boot).
    SOURCES = {
      "hep3" => "DataTable::Hep3Source",
      "logs" => "DataTable::LogsSource",
      "http" => "DataTable::HttpSource"
    }.freeze

    # build — instantiate the source for `key` from request params, or
    # nil when the key is unknown or the params don't resolve a valid
    # source (the controller turns nil into a 404).
    def self.build(key, server:, params:)
      class_name = SOURCES[key.to_s]
      return nil unless class_name

      class_name.constantize.from_params(server: server, params: params)
    end

    def self.registered?(key)
      SOURCES.key?(key.to_s)
    end

    # available — source metadata for the panel builder's Table form, for
    # the sources applicable to this server: [{key:, label:, views:[…]}].
    # The form's source dropdown lists these; the view dropdown reads each
    # source's `views`. Currently just hep3 (when its plugin is installed).
    def self.available(server)
      SOURCES.keys.filter_map do |key|
        klass = SOURCES[key].constantize
        next unless klass.available_for?(server)

        {key: key, label: klass.label, short_label: klass.short_label, views: klass.view_options}
      end
    end
  end
end
