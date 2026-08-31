require_relative "../../spec_helper"
require "test_plan/dependency_delta"

RSpec.describe TestPlan::DependencyDelta::BundlerChangeDetector do
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

  it "reports no remote when a GEM section lists several" do
    # The lockfile does not attribute a spec to one of them, so naming the first would
    # let an internal gem read as public whenever rubygems.org sorts first.
    lock = lambda do |version|
      <<~LOCK
        GEM
          remote: https://gems.internal.example/
          remote: https://rubygems.org/
          specs:
            shared_gem (#{version})

        DEPENDENCIES
          shared_gem
      LOCK
    end

    changes = described_class.new.detect(
      path: "Gemfile.lock", old_content: lock.call("1.0.0"), new_content: lock.call("2.0.0")
    )

    expect(changes.length).to eq(1)
    expect(changes.first.new_locator).to eq("")
    expect(TestPlan::DependencyDelta::PublicOrigin.rubygems_public?(changes.first)).to be(false)
  end

  it "keeps the remote when a GEM section lists exactly one" do
    lock = lambda do |version|
      <<~LOCK
        GEM
          remote: https://rubygems.org/
          specs:
            shared_gem (#{version})

        DEPENDENCIES
          shared_gem
      LOCK
    end

    changes = described_class.new.detect(
      path: "Gemfile.lock", old_content: lock.call("1.0.0"), new_content: lock.call("2.0.0")
    )

    expect(changes.first.new_locator).to eq("https://rubygems.org/")
    expect(TestPlan::DependencyDelta::PublicOrigin.rubygems_public?(changes.first)).to be(true)
  end

  it "reports a gem that moved from RubyGems to a Git source" do
    from_gem = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          moving_gem (1.0.0)

      DEPENDENCIES
        moving_gem
    LOCK
    to_git = <<~LOCK
      GIT
        remote: https://github.com/example/moving_gem.git
        revision: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        specs:
          moving_gem (2.0.0)

      DEPENDENCIES
        moving_gem!
    LOCK

    changes = described_class.new.detect(
      path: "Gemfile.lock", old_content: from_gem, new_content: to_git
    )

    # Previously dropped entirely: new_git was present while old_git was nil.
    expect(changes.map(&:source)).to eq(["mixed"])
    expect(changes.first).to have_attributes(
      old_version: "1.0.0", new_version: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    )
  end

  it "reports a gem that moved from a Git source back to RubyGems" do
    from_git = <<~LOCK
      GIT
        remote: https://github.com/example/moving_gem.git
        revision: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        specs:
          moving_gem (1.0.0)

      DEPENDENCIES
        moving_gem!
    LOCK
    to_gem = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          moving_gem (2.0.0)

      DEPENDENCIES
        moving_gem
    LOCK

    changes = described_class.new.detect(
      path: "Gemfile.lock", old_content: from_git, new_content: to_gem
    )

    expect(changes.map(&:source)).to eq(["mixed"])
    expect(changes.first).to have_attributes(
      old_version: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", new_version: "2.0.0"
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
