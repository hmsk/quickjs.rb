# frozen_string_literal: true

require "test_helper"
require "rbs"
require "pathname"

describe "RBS completeness" do
  before do
    env = RBS::Environment.new
    loader = RBS::EnvironmentLoader.new
    loader.add(path: Pathname(File.expand_path("../sig", __dir__)))
    loader.load(env: env)
    @env = env.resolve_type_names
    @builder = RBS::DefinitionBuilder.new(env: @env)
  end

  it "declares all public Quickjs::VM instance methods" do
    type_name = RBS::TypeName.parse("::Quickjs::VM")
    rbs_methods = @env.class_decls[type_name].decls
      .flat_map { |d| d.decl.members.grep(RBS::AST::Members::MethodDefinition) }
      .reject { |m| m.kind == :singleton || m.name.to_s == "initialize" }
      .map { |m| m.name.to_s }
      .to_set

    actual = Quickjs::VM.public_instance_methods(false).map(&:to_s).to_set
    missing = actual - rbs_methods
    assert missing.empty?, "VM methods missing from RBS: #{missing.sort.join(", ")}"
    stale = rbs_methods - actual
    assert stale.empty?, "RBS declares non-existent VM methods: #{stale.sort.join(", ")}"
  end

  it "declares all Quickjs Symbol constants" do
    rbs_constants = @env.constant_decls.keys
      .select { |name| name.namespace.absolute? && name.namespace.path == [:Quickjs] }
      .map { |name| name.name.to_s }
      .to_set

    actual = Quickjs.constants
      .select { |c| Quickjs.const_get(c).is_a?(Symbol) }
      .map(&:to_s)
      .to_set

    missing = actual - rbs_constants
    assert missing.empty?, "Quickjs constants missing from RBS: #{missing.sort.join(", ")}"
  end
end
