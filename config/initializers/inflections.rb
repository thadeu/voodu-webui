# Be sure to restart your server when you modify this file.

# Add new inflection rules using the following format. Inflections
# are locale specific, and you may define rules for as many different
# locales as you wish. All of these examples are active by default:
# ActiveSupport::Inflector.inflections(:en) do |inflect|
#   inflect.plural /^(ox)$/i, "\\1en"
#   inflect.singular /^(ox)en/i, "\\1"
#   inflect.irregular "person", "people"
#   inflect.uncountable %w( fish sheep )
# end

# Acronyms — required so Zeitwerk can resolve `app/components/ui/foo.rb`
# as `Components::UI::Foo` (not `Components::Ui::Foo`). Mirrors clowk.
ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.acronym "UI"
end
