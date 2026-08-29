require_relative "../../spec_helper"
require "test_plan/dependency_delta/change_detector"

require "json"
require "set"

describe TestPlan::DependencyDelta::ChangeDetector do
  class FakeSnapshot
    attr_reader :base_sha, :merge_base_sha, :head_sha

    def initialize(files)
      @files = files
      @base_sha = "base_tip"
      @merge_base_sha = "merge_base"
      @head_sha = "head"
    end

    def changed_dependency_files
      ["yarn.lock"]
    end

    def paths_at(_ref, suffix)
      @files.fetch("head").keys.select { |path| path.end_with?(suffix) }
    end

    def read(ref, path)
      @files.fetch(ref).fetch(path, nil)
    end
  end

  it "excludes Yarn workspaces and file/link dependencies" do
    old_lock = <<~LOCK
      external@^1.0.0:
        version "1.0.0"
      local-file@file:vendor/local-file:
        version "1.0.0"
      local-link@link:components/local-link:
        version "1.0.0"
      local-workspace@^1.0.0:
        version "1.0.0"
    LOCK
    new_lock = old_lock.gsub('version "1.0.0"', 'version "2.0.0"')
    snapshot = FakeSnapshot.new(
      "merge_base" => { "yarn.lock" => old_lock },
      "head" => {
        "yarn.lock" => new_lock,
        "package.json" => JSON.generate(
          "workspaces" => ["components/*"],
          "dependencies" => {
            "external" => "^2.0.0",
            "local-file" => "file:vendor/local-file",
            "local-link" => "link:components/local-link",
            "local-workspace" => "^2.0.0",
          }
        ),
        "components/local-workspace/package.json" => JSON.generate("name" => "local-workspace"),
      }
    )

    changes = described_class.new(snapshot).detect
    expect(changes.map(&:name)).to eq(["external"])
    expect(changes.first.direct).to be(true)
  end

  it "deduplicates the same raise across lockfiles" do
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
    snapshot = FakeSnapshot.new(
      "merge_base" => {
        "one/Gemfile.lock" => lock.call("1.0.0"),
        "two/Gemfile.lock" => lock.call("1.0.0"),
      },
      "head" => {
        "one/Gemfile.lock" => lock.call("2.0.0"),
        "two/Gemfile.lock" => lock.call("2.0.0"),
      }
    )
    allow(snapshot).to receive(:changed_dependency_files).and_return(
      ["one/Gemfile.lock", "two/Gemfile.lock"]
    )

    changes = described_class.new(snapshot).detect
    expect(changes.length).to eq(1)
    expect(changes.first.lockfiles).to contain_exactly("one/Gemfile.lock", "two/Gemfile.lock")
  end

  it "deduplicates a raise recorded through different registry remotes" do
    lock = lambda do |remote, version|
      <<~LOCK
        GEM
          remote: #{remote}
          specs:
            shared_gem (#{version})

        DEPENDENCIES
          shared_gem
      LOCK
    end
    snapshot = FakeSnapshot.new(
      "merge_base" => {
        "one/Gemfile.lock" => lock.call("https://rubygems.org/", "1.0.0"),
        "two/Gemfile.lock" => lock.call("https://rubygems.org", "1.0.0"),
      },
      "head" => {
        "one/Gemfile.lock" => lock.call("https://rubygems.org/", "2.0.0"),
        "two/Gemfile.lock" => lock.call("https://rubygems.org", "2.0.0"),
      }
    )
    allow(snapshot).to receive(:changed_dependency_files).and_return(
      ["one/Gemfile.lock", "two/Gemfile.lock"]
    )

    changes = described_class.new(snapshot).detect

    expect(changes.length).to eq(1)
    expect(changes.first.lockfiles).to contain_exactly("one/Gemfile.lock", "two/Gemfile.lock")
  end

  it "keeps Git raises from different repositories separate" do
    same_repo = TestPlan::DependencyDelta::Change.new(
      ecosystem: "yarn", name: "widget", old_version: "aaa", new_version: "bbb", source: "git",
      old_locator: "git+https://github.com/example/widget.git#aaa",
      new_locator: "https://codeload.github.com/example/widget/tar.gz/bbb",
      direct: true, lockfiles: ["a/yarn.lock"]
    )
    equivalent = same_repo.dup.tap { |change| change.lockfiles = ["b/yarn.lock"] }
    forked = TestPlan::DependencyDelta::Change.new(
      ecosystem: "yarn", name: "widget", old_version: "aaa", new_version: "bbb", source: "git",
      old_locator: "git+https://github.com/example/widget.git#aaa",
      new_locator: "https://codeload.github.com/someone/widget-fork/tar.gz/bbb",
      direct: true, lockfiles: ["c/yarn.lock"]
    )

    expect(same_repo.key).to eq(equivalent.key)
    expect(same_repo.key).not_to eq(forked.key)
  end

  it "compares against the merge base rather than the base tip" do
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
    snapshot = FakeSnapshot.new(
      "merge_base" => { "Gemfile.lock" => lock.call("1.0.0") },
      # The base branch raised the gem further after this PR forked. That raise
      # belongs to the base branch, not to this PR.
      "base_tip" => { "Gemfile.lock" => lock.call("3.0.0") },
      "head" => { "Gemfile.lock" => lock.call("2.0.0") }
    )
    allow(snapshot).to receive(:changed_dependency_files).and_return(["Gemfile.lock"])

    changes = described_class.new(snapshot).detect

    expect(changes.length).to eq(1)
    expect(changes.first).to have_attributes(old_version: "1.0.0", new_version: "2.0.0")
  end

  it "records an unreadable lockfile as a problem and keeps analyzing the others" do
    readable = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          good_gem (VERSION)

      DEPENDENCIES
        good_gem
    LOCK
    snapshot = FakeSnapshot.new(
      "merge_base" => {
        "broken/Gemfile.lock" => "GEM\n  remote: https://rubygems.org/\n  specs:\n    bad_gem (not-a-version)\n",
        "good/Gemfile.lock" => readable.sub("VERSION", "1.0.0"),
      },
      "head" => {
        "broken/Gemfile.lock" => "GEM\n  remote: https://rubygems.org/\n  specs:\n    bad_gem (also-bad)\n",
        "good/Gemfile.lock" => readable.sub("VERSION", "2.0.0"),
      }
    )
    allow(snapshot).to receive(:changed_dependency_files).and_return(
      ["broken/Gemfile.lock", "good/Gemfile.lock"]
    )

    detector = described_class.new(snapshot)
    changes = detector.detect

    expect(changes.map(&:name)).to eq(["good_gem"])
    expect(detector.problems.map(&:path)).to eq(["broken/Gemfile.lock"])
    expect(detector.problems.first.message).to include("Unable to parse broken/Gemfile.lock")
  end
end
