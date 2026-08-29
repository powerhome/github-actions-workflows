require_relative "../../spec_helper"
require "test_plan/dependency_delta/bundler_change_detector"

describe TestPlan::DependencyDelta::BundlerChangeDetector do
  let(:old_lock) do
    <<~LOCK
      GIT
        remote: https://github.com/example/tool.git
        revision: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        specs:
          git_tool (1.0.0)

      PATH
        remote: components
        specs:
          internal_component (0.0.1)

      GEM
        remote: https://rubygems.org/
        specs:
          direct_gem (1.0.0)
          transitive_gem (2.0.0)

      DEPENDENCIES
        direct_gem
        git_tool!
        internal_component!
    LOCK
  end

  let(:new_lock) do
    <<~LOCK
      GIT
        remote: https://github.com/example/tool.git
        revision: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        specs:
          git_tool (1.0.0)

      PATH
        remote: components
        specs:
          internal_component (0.0.2)

      GEM
        remote: https://rubygems.org/
        specs:
          direct_gem (1.1.0)
          transitive_gem (2.1.0)

      DEPENDENCIES
        direct_gem
        git_tool!
        internal_component!
    LOCK
  end

  it "detects direct, transitive, and Git raises while excluding PATH components" do
    changes = described_class.new.detect(
      path: "Gemfile.lock",
      old_content: old_lock,
      new_content: new_lock
    )

    expect(changes.map(&:name)).to contain_exactly("direct_gem", "transitive_gem", "git_tool")
    expect(changes.find { |change| change.name == "direct_gem" }.direct).to be(true)
    expect(changes.find { |change| change.name == "transitive_gem" }.direct).to be(false)
    expect(changes.find { |change| change.name == "git_tool" }).to have_attributes(
      source: "git",
      old_version: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      new_version: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    )
  end

  it "ignores decreases and removals" do
    changes = described_class.new.detect(
      path: "Gemfile.lock",
      old_content: new_lock,
      new_content: old_lock
    )
    expect(changes.map(&:name)).to eq(["git_tool"])
  end
end
