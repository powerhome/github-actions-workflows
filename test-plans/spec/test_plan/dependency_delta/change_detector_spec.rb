require_relative "../../spec_helper"
require "test_plan/dependency_delta"

require "json"
require "set"

RSpec.describe TestPlan::DependencyDelta::ChangeDetector do
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

  def gem_lock(version)
    <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          shared_gem (#{version})

      DEPENDENCIES
        shared_gem
    LOCK
  end

  def scoped_snapshot(paths)
    snapshot = FakeSnapshot.new(
      "merge_base" => paths.to_h { |path| [path, gem_lock("1.0.0")] },
      "head" => paths.to_h { |path| [path, gem_lock("2.0.0")] }
    )
    allow(snapshot).to receive(:changed_dependency_files).and_return(paths)
    snapshot
  end

  describe "dependency scope" do
    # Only the umbrella application is deployed, so a raise confined to an unmounted
    # component's lockfile changes nothing a tester can open.
    it "skips a raise that reached no root lockfile" do
      detector = described_class.new(scoped_snapshot(["components/pigment/Gemfile.lock"]))

      expect(detector.detect).to be_empty
      expect(detector.out_of_scope.map(&:name)).to eq(["shared_gem"])
    end

    it "keeps a raise in a root lockfile" do
      detector = described_class.new(scoped_snapshot(["Gemfile.lock"]))

      expect(detector.detect.map(&:name)).to eq(["shared_gem"])
      expect(detector.out_of_scope).to be_empty
    end

    # Deduplication runs first, so the root copy carries the component ones with it.
    it "keeps a raise recorded in both a root and a component lockfile" do
      detector = described_class.new(
        scoped_snapshot(["Gemfile.lock", "components/pigment/Gemfile.lock"])
      )
      changes = detector.detect

      expect(changes.map(&:name)).to eq(["shared_gem"])
      expect(changes.first.lockfiles).to include("components/pigment/Gemfile.lock")
      expect(detector.out_of_scope).to be_empty
    end

    it "analyzes every lockfile when told to" do
      detector = described_class.new(
        scoped_snapshot(["components/pigment/Gemfile.lock"]), scope: "all"
      )

      expect(detector.detect.map(&:name)).to eq(["shared_gem"])
      expect(detector.out_of_scope).to be_empty
    end

    it "refuses a scope it does not know" do
      expect { described_class.new(scoped_snapshot(["Gemfile.lock"]), scope: "components") }
        .to raise_error(/Unknown dependency scope/)
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

    changes = described_class.new(snapshot, scope: "all").detect
    expect(changes.length).to eq(1)
    expect(changes.first.lockfiles).to contain_exactly("one/Gemfile.lock", "two/Gemfile.lock")
  end

  it "resolves a nested package's workspace globs relative to its own directory" do
    old_lock = <<~LOCK
      external@^1.0.0:
        version "1.0.0"
      nested-widget@^1.0.0:
        version "1.0.0"
    LOCK
    new_lock = old_lock.gsub('version "1.0.0"', 'version "2.0.0"')
    snapshot = FakeSnapshot.new(
      "merge_base" => { "yarn.lock" => old_lock },
      "head" => {
        "yarn.lock" => new_lock,
        "package.json" => JSON.generate(
          "dependencies" => { "external" => "^2.0.0", "nested-widget" => "^2.0.0" }
        ),
        # Declares its members relative to itself, not to the repository root.
        "apps/site/package.json" => JSON.generate(
          "name" => "site", "workspaces" => ["packages/*"]
        ),
        "apps/site/packages/widget/package.json" => JSON.generate("name" => "nested-widget"),
      }
    )
    allow(snapshot).to receive(:changed_dependency_files).and_return(["yarn.lock"])

    changes = described_class.new(snapshot).detect

    # nested-widget is a workspace member, so its bump is local, not an external raise.
    expect(changes.map(&:name)).to eq(["external"])
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

    changes = described_class.new(snapshot, scope: "all").detect

    expect(changes.length).to eq(1)
    expect(changes.first.lockfiles).to contain_exactly("one/Gemfile.lock", "two/Gemfile.lock")
  end

  it "keeps a private package separate from a public one of the same name" do
    public_change = TestPlan::DependencyDelta::Change.new(
      ecosystem: "yarn", name: "widget", old_version: "1.0.0", new_version: "2.0.0",
      source: "npm", old_locator: "https://registry.npmjs.org/widget/-/widget-1.0.0.tgz",
      new_locator: "https://registry.npmjs.org/widget/-/widget-2.0.0.tgz",
      direct: true, lockfiles: ["a/yarn.lock"]
    )
    private_change = TestPlan::DependencyDelta::Change.new(
      ecosystem: "yarn", name: "widget", old_version: "1.0.0", new_version: "2.0.0",
      source: "npm", old_locator: "https://npm.internal.example/widget/-/widget-1.0.0.tgz",
      new_locator: "https://npm.internal.example/widget/-/widget-2.0.0.tgz",
      direct: true, lockfiles: ["b/yarn.lock"]
    )

    # Collapsing these would apply one entry's provenance to both, either feeding the
    # private dependency unrelated public source or suppressing valid public evidence.
    expect(public_change.key).not_to eq(private_change.key)
  end

  it "collapses mirrors of one package that share a checksum" do
    through = lambda do |host, lockfile|
      TestPlan::DependencyDelta::Change.new(
        ecosystem: "yarn", name: "widget", old_version: "1.0.0", new_version: "2.0.0",
        source: "npm", old_locator: "https://#{host}/widget-1.0.0.tgz",
        new_locator: "https://#{host}/widget-2.0.0.tgz",
        old_integrity: "sha512-old==", new_integrity: "sha512-new==",
        direct: true, lockfiles: [lockfile]
      )
    end

    expect(through.call("registry.npmjs.org", "a/yarn.lock").key)
      .to eq(through.call("npm.mirror.example", "b/yarn.lock").key)
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

    detector = described_class.new(snapshot, scope: "all")
    changes = detector.detect

    expect(changes.map(&:name)).to eq(["good_gem"])
    expect(detector.problems.map(&:path)).to eq(["broken/Gemfile.lock"])
    expect(detector.problems.first.message).to include("Unable to parse broken/Gemfile.lock")
  end

  # Which names count as direct decides ordering and how much of the context budget a
  # raise gets, so reading a manifest loosely both promotes dependencies nobody declared
  # and, through the quote pairing, demotes ones somebody did.
  describe "reading direct dependencies out of a manifest" do
    def bumping(manifests)
      lock = lambda do |version|
        <<~LOCK
          GEM
            remote: https://rubygems.org/
            specs:
              rack (#{version})
              sidekiq (#{version})
              sinatra (#{version})

          DEPENDENCIES
            sinatra
        LOCK
      end
      snapshot = FakeSnapshot.new(
        "merge_base" => { "Gemfile.lock" => lock.call("1.0.0") },
        "head" => { "Gemfile.lock" => lock.call("2.0.0") }.merge(manifests)
      )
      allow(snapshot).to receive(:changed_dependency_files).and_return(["Gemfile.lock"])
      described_class.new(snapshot, scope: "all").detect
    end

    it "ignores an entry that was commented out rather than deleted" do
      changes = bumping(
        "Gemfile" => <<~GEMFILE
          # gem "rack"
          gem "sinatra"
        GEMFILE
      )

      expect(changes.select(&:direct).map(&:name)).to eq(["sinatra"])
    end

    it "still sees a declaration that follows prose containing an apostrophe" do
      # The comment bundler's own `gem` template writes. Unanchored, its apostrophe
      # opened a quote whose capture ran to the next one in the file -- the opening
      # quote of the declaration below -- swallowing the name it was looking for.
      changes = bumping(
        "Gemfile" => <<~GEMFILE
          # Specify your gem's dependencies in widget.gemspec
          gem "rack"
        GEMFILE
      )

      expect(changes.select(&:direct).map(&:name)).to contain_exactly("rack", "sinatra")
    end

    it "reads a gemspec through the receiver it names" do
      changes = bumping(
        "widget.gemspec" => <<~GEMSPEC
          Gem::Specification.new do |spec|
            spec.add_dependency "rack"
            # spec.add_dependency "sidekiq"
          end
        GEMSPEC
      )

      expect(changes.select(&:direct).map(&:name)).to contain_exactly("rack", "sinatra")
    end
  end
end
