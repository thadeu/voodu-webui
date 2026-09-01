# frozen_string_literal: true

require "test_helper"
require "prism"

# No token-signing secret is written down in this repository.
#
# Clowk::JwtVerifier routes a token to the HS256 path whenever its `alg` is not
# RS256, and that path does not check the audience — so whatever
# `Clowk.config.secret_key` holds is, by itself, enough to mint a token for any
# subject and any address. A literal here is not a weak default; it is a
# published credential that authenticates anyone who reads this file.
#
# It was one, until 2026-09-01: the initializer fell back to a fixed string
# whenever CLOWK_SECRET_KEY was unset — which is the arrangement .env.example
# calls normal, because RS256 verification needs no secret at all. Production
# now resolves to nil, the verifier raises "missing Clowk secret_key", and the
# legacy path is shut. Development and test derive one from secret_key_base,
# which is machine-local and never committed.
#
# PARSED, not grepped, and by RESULT POSITION rather than by "contains a
# string". Two earlier versions of this test were wrong in opposite directions:
# the first matched only the assignment line and passed while the fallback sat
# two lines below inside an `elsif`; the second flagged every string anywhere in
# the expression, including the name of the environment variable being read. A
# guard that cannot fail is worse than none, and one that fails on correct code
# gets deleted. What is dangerous is a string the expression can RETURN.
class NoSharedAuthSecretTest < ActiveSupport::TestCase
  SOURCES = %w[config/initializers app/services app/models app/controllers].freeze

  # `secret_key = x` and `config.secret_key = x` parse as different nodes.
  def secret_key_value(node)
    return node.arguments if node.is_a?(Prism::CallNode) && node.name == :secret_key=
    return node.value if node.is_a?(Prism::LocalVariableWriteNode) && node.name == :secret_key

    nil
  end

  # Every string this expression could evaluate to. Descends through the shapes
  # that PASS a value through — branches, `||`, a statement list's last line —
  # and stops at calls, whose arguments are inputs rather than results. The one
  # exception is ENV.fetch's default, which is a result and a realistic way to
  # smuggle one back in.
  def returnable_strings(node)
    case node
    when nil then []
    when Prism::StringNode then [node.unescaped]
    when Prism::IfNode, Prism::UnlessNode
      returnable_strings(node.statements) + returnable_strings(node.subsequent)
    when Prism::ElseNode then returnable_strings(node.statements)
    when Prism::OrNode then returnable_strings(node.left) + returnable_strings(node.right)
    when Prism::AndNode then returnable_strings(node.right)
    when Prism::StatementsNode then node.body.flat_map { |child| returnable_strings(child) }
    when Prism::ParenthesesNode, Prism::BeginNode then returnable_strings(node.statements)
    when Prism::ArgumentsNode then node.arguments.flat_map { |child| returnable_strings(child) }
    when Prism::CallNode
      # ENV.fetch("KEY", "fallback") — the second argument is what you get.
      return [] unless node.name == :fetch

      node.arguments&.arguments.to_a.drop(1).flat_map { |child| returnable_strings(child) }
    else []
    end
  end

  def offenders_in(path)
    found = []

    walk = lambda { |node|
      return unless node.is_a?(Prism::Node)

      returnable_strings(secret_key_value(node)).each { |literal| found << literal }
      node.compact_child_nodes.each { |child| walk.call(child) }
    }
    walk.call(Prism.parse(Pathname(path).read).value)

    found.map { |literal| "#{Pathname(path).relative_path_from(Rails.root)}: #{literal.inspect}" }
  end

  test "nothing in the app can return a written-down secret_key" do
    offenders = SOURCES.flat_map { |dir| Dir[Rails.root.join(dir, "**/*.rb")].flat_map { |p| offenders_in(p) } }

    assert_empty offenders,
      "a written-down secret_key authenticates anyone who reads this repository — " \
      "resolve it from ENV, or derive it from secret_key_base outside production"
  end

  # The guard above proves the shape; this proves the walker still has teeth,
  # because a security test that silently stops matching is the failure mode
  # this file has already had twice.
  test "the walker catches a fallback wherever it is hidden" do
    hiding_places = [
      'config.secret_key = "hardcoded-secret-value"',
      'config.secret_key = ENV["CLOWK_SECRET_KEY"] || "hardcoded-secret-value"',
      'config.secret_key = ENV.fetch("CLOWK_SECRET_KEY", "hardcoded-secret-value")',
      <<~RUBY,
        config.secret_key =
          if supplied
            supplied
          elsif !Rails.env.production?
            "hardcoded-secret-value"
          end
      RUBY
      <<~RUBY
        secret_key = if x then y else "hardcoded-secret-value" end
      RUBY
    ]

    hiding_places.each do |source|
      found = []
      walk = lambda { |node|
        return unless node.is_a?(Prism::Node)

        found.concat(returnable_strings(secret_key_value(node)))
        node.compact_child_nodes.each { |child| walk.call(child) }
      }
      walk.call(Prism.parse(source).value)

      assert_includes found, "hardcoded-secret-value", "missed it in:\n#{source}"
    end
  end

  # And that it does NOT fire on the correct code, so nobody deletes it for
  # crying wolf: the env var's NAME and the derivation's salt are both strings,
  # and neither is a credential.
  test "and leaves the legitimate strings alone" do
    source = <<~RUBY
      config.secret_key =
        if (supplied = ENV.fetch("CLOWK_SECRET_KEY", nil).presence)
          supplied
        elsif !Rails.env.production?
          Rails.application.key_generator.generate_key("clowk dev sign-in", 32)
        end
    RUBY

    found = []
    walk = lambda { |node|
      return unless node.is_a?(Prism::Node)

      found.concat(returnable_strings(secret_key_value(node)))
      node.compact_child_nodes.each { |child| walk.call(child) }
    }
    walk.call(Prism.parse(source).value)

    assert_empty found
  end
end
