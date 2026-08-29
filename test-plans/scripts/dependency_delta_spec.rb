#!/usr/bin/env ruby
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "rspec", "~> 3.13"
end

require "fileutils"
require "open3"
require "rspec/autorun"
require "stringio"
require "tmpdir"
require "zlib"

require_relative "dependency_delta"

RSpec.describe "dependency delta generation" do
  describe BundlerChangeDetector do
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

  describe YarnChangeDetector do
    let(:old_lock) do
      <<~LOCK
        # yarn lockfile v1
        direct-package@^1.0.0:
          version "1.0.0"
          resolved "https://npm.powerapp.cloud/direct-package/-/direct-package-1.0.0.tgz"

        transitive-package@^2.0.0:
          version "2.0.0"
          resolved "https://npm.powerapp.cloud/transitive-package/-/transitive-package-2.0.0.tgz"

        "@powerhome/local@0.0.1":
          version "0.0.1"
      LOCK
    end

    let(:new_lock) do
      <<~LOCK
        # yarn lockfile v1
        direct-package@^1.0.0:
          version "1.1.0"
          resolved "https://npm.powerapp.cloud/direct-package/-/direct-package-1.1.0.tgz"

        transitive-package@^2.0.0:
          version "2.2.0"
          resolved "https://npm.powerapp.cloud/transitive-package/-/transitive-package-2.2.0.tgz"

        "@powerhome/local@0.0.1":
          version "0.0.2"
      LOCK
    end

    it "detects npm raises and excludes workspace packages" do
      changes = described_class.new.detect(
        path: "yarn.lock",
        old_content: old_lock,
        new_content: new_lock,
        direct_names: Set["direct-package"],
        workspace_names: Set["@powerhome/local"]
      )

      expect(changes.map(&:name)).to contain_exactly("direct-package", "transitive-package")
      expect(changes.find { |change| change.name == "direct-package" }.direct).to be(true)
      expect(changes.find { |change| change.name == "transitive-package" }.direct).to be(false)
    end

    it "ignores decreases and removals" do
      old_lock = <<~LOCK
        downgraded@^2.0.0:
          version "2.0.0"
          resolved "https://registry.npmjs.org/downgraded/-/downgraded-2.0.0.tgz"

        removed@^1.0.0:
          version "1.0.0"
          resolved "https://registry.npmjs.org/removed/-/removed-1.0.0.tgz"
      LOCK
      new_lock = <<~LOCK
        downgraded@^1.0.0:
          version "1.0.0"
          resolved "https://registry.npmjs.org/downgraded/-/downgraded-1.0.0.tgz"
      LOCK

      changes = described_class.new.detect(
        path: "yarn.lock",
        old_content: old_lock,
        new_content: new_lock,
        direct_names: Set["downgraded", "removed"],
        workspace_names: Set.new
      )

      expect(changes).to be_empty
    end

    it "detects a Git revision change when the declared version is unchanged" do
      old_lock = <<~LOCK
        git-package@github:example/git-package#aaaaaaa:
          version "1.0.0"
          resolved "https://codeload.github.com/example/git-package/tar.gz/aaaaaaa"
      LOCK
      new_lock = <<~LOCK
        git-package@github:example/git-package#bbbbbbb:
          version "1.0.0"
          resolved "https://codeload.github.com/example/git-package/tar.gz/bbbbbbb"
      LOCK

      changes = described_class.new.detect(
        path: "yarn.lock",
        old_content: old_lock,
        new_content: new_lock,
        direct_names: Set["git-package"],
        workspace_names: Set.new
      )

      expect(changes.length).to eq(1)
      expect(changes.first).to have_attributes(
        source: "git",
        old_version: "aaaaaaa",
        new_version: "bbbbbbb"
      )
    end

    it "detects a Git dependency that changes version and revision together" do
      old_lock = <<~LOCK
        git-package@github:example/git-package#aaaaaaa:
          version "1.0.0"
          resolved "https://codeload.github.com/example/git-package/tar.gz/aaaaaaa"
      LOCK
      new_lock = <<~LOCK
        git-package@github:example/git-package#bbbbbbb:
          version "2.0.0"
          resolved "https://codeload.github.com/example/git-package/tar.gz/bbbbbbb"
      LOCK

      changes = described_class.new.detect(
        path: "yarn.lock",
        old_content: old_lock,
        new_content: new_lock,
        direct_names: Set["git-package"],
        workspace_names: Set.new
      )

      expect(changes.length).to eq(1)
      expect(changes.first).to have_attributes(
        source: "git",
        old_version: "aaaaaaa",
        new_version: "bbbbbbb"
      )
    end
  end

  describe DependencyChangeDetector do
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
      same_repo = DependencyChange.new(
        ecosystem: "yarn", name: "widget", old_version: "aaa", new_version: "bbb", source: "git",
        old_locator: "git+https://github.com/example/widget.git#aaa",
        new_locator: "https://codeload.github.com/example/widget/tar.gz/bbb",
        direct: true, lockfiles: ["a/yarn.lock"]
      )
      equivalent = same_repo.dup.tap { |change| change.lockfiles = ["b/yarn.lock"] }
      forked = DependencyChange.new(
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

  describe PublicDependencyRetriever do
    class FakeDownloader
      attr_reader :downloaded

      def initialize(dists: {})
        @dists = dists
        @downloaded = []
      end

      def download(url, destination)
        @downloaded << url
        FileUtils.touch(destination)
        destination
      end

      def npm_dist(name, version)
        @dists.fetch([name, version])
      end
    end

    class NullExtractor
      def extract_gzip(_path, _destination) = nil
      def extract_gem(_path, _destination) = nil
    end

    # Materializes a predetermined tree per call, old side first, so the wrapper
    # handling can be checked through the diff paths it produces.
    class LayoutExtractor
      def initialize(layouts)
        @layouts = layouts.dup
      end

      def extract_gzip(_path, destination) = write(@layouts.shift, destination)
      def extract_gem(_path, destination) = write(@layouts.shift, destination)

    private

      def write(layout, destination)
        layout.each do |path, content|
          full = File.join(destination, path)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, content)
        end
      end
    end

    def retriever(downloader)
      described_class.new(downloader: downloader, extractor: NullExtractor.new)
    end

    def npm_change(locator:, integrity:)
      DependencyChange.new(
        ecosystem: "yarn", name: "widget", old_version: "1.0.0", new_version: "2.0.0",
        source: "npm", old_locator: locator.call("1.0.0"), new_locator: locator.call("2.0.0"),
        old_integrity: integrity, new_integrity: integrity,
        direct: true, lockfiles: ["yarn.lock"]
      )
    end

    let(:private_locator) do
      ->(version) { "https://npm.powerapp.cloud/widget/-/widget-#{version}.tgz" }
    end

    let(:public_dists) do
      {
        ["widget", "1.0.0"] => {
          "tarball" => "https://registry.npmjs.org/widget/-/widget-1.0.0.tgz",
          "integrity" => "sha512-matching==",
          "shasum" => "aaa111",
        },
        ["widget", "2.0.0"] => {
          "tarball" => "https://registry.npmjs.org/widget/-/widget-2.0.0.tgz",
          "integrity" => "sha512-matching==",
          "shasum" => "bbb222",
        },
      }
    end

    it "strips the npm wrapper directory from both sides" do
      downloader = FakeDownloader.new(dists: public_dists)
      extractor = LayoutExtractor.new(
        [
          { "package/lib/widget.js" => "old\n", "package/README.md" => "same\n" },
          { "package/lib/widget.js" => "new\n", "package/README.md" => "same\n" },
        ]
      )
      change = npm_change(
        locator: ->(version) { "https://registry.npmjs.org/widget/-/widget-#{version}.tgz" },
        integrity: nil
      )

      chunks = described_class.new(downloader: downloader, extractor: extractor).retrieve(change)

      expect(chunks.map(&:path)).to eq(["lib/widget.js"])
      expect(chunks.first.diff).to include("a/lib/widget.js", "b/lib/widget.js")
    end

    it "keeps both roots intact when only one side has a single directory" do
      downloader = FakeDownloader.new(dists: public_dists)
      extractor = LayoutExtractor.new(
        [
          { "lib/widget.js" => "old\n", "README.md" => "dropped\n" },
          { "lib/widget.js" => "new\n" },
        ]
      )
      change = npm_change(
        locator: ->(version) { "https://registry.npmjs.org/widget/-/widget-#{version}.tgz" },
        integrity: nil
      )

      chunks = described_class.new(downloader: downloader, extractor: extractor).retrieve(change)

      # Descending into the new side's lone "lib/" would have offset the roots and
      # reported every file as removed and re-added.
      expect(chunks.map(&:path)).to contain_exactly("lib/widget.js", "README.md")
      expect(chunks.map(&:diff).join).to include("a/lib/widget.js", "b/lib/widget.js", "a/README.md")
    end

    it "never strips a wrapper for gems, whose data archives have none" do
      downloader = FakeDownloader.new
      extractor = LayoutExtractor.new(
        [{ "lib/widget.rb" => "old\n" }, { "lib/widget.rb" => "new\n" }]
      )
      change = DependencyChange.new(
        ecosystem: "bundler", name: "widget", old_version: "1.0.0", new_version: "2.0.0",
        source: "rubygems", old_locator: "https://rubygems.org/",
        new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
      )

      chunks = described_class.new(downloader: downloader, extractor: extractor).retrieve(change)

      expect(chunks.map(&:path)).to eq(["lib/widget.rb"])
      expect(chunks.first.diff).to include("a/lib/widget.rb", "b/lib/widget.rb")
    end

    it "refuses gems that did not resolve from rubygems.org" do
      downloader = FakeDownloader.new
      change = DependencyChange.new(
        ecosystem: "bundler", name: "internal_gem", old_version: "1.0.0", new_version: "2.0.0",
        source: "rubygems", old_locator: "https://gems.powerapp.cloud/",
        new_locator: "https://gems.powerapp.cloud/", direct: true, lockfiles: ["Gemfile.lock"]
      )

      expect { retriever(downloader).retrieve(change) }
        .to raise_error(RuntimeError, /non-public RubyGems source/)
      expect(downloader.downloaded).to be_empty
    end

    it "retrieves npm packages resolved directly from the public registry" do
      downloader = FakeDownloader.new(dists: public_dists)
      change = npm_change(
        locator: ->(version) { "https://registry.yarnpkg.com/widget/-/widget-#{version}.tgz" },
        integrity: nil
      )

      retriever(downloader).retrieve(change)

      expect(downloader.downloaded).to eq(
        [
          "https://registry.npmjs.org/widget/-/widget-1.0.0.tgz",
          "https://registry.npmjs.org/widget/-/widget-2.0.0.tgz",
        ]
      )
    end

    it "accepts a private-registry package whose lockfile checksum matches the public one" do
      downloader = FakeDownloader.new(dists: public_dists)
      change = npm_change(locator: private_locator, integrity: "sha512-matching==")

      retriever(downloader).retrieve(change)

      expect(downloader.downloaded.length).to eq(2)
    end

    it "refuses a private-registry package whose checksum does not match the public one" do
      downloader = FakeDownloader.new(dists: public_dists)
      change = npm_change(locator: private_locator, integrity: "sha512-something-else==")

      expect { retriever(downloader).retrieve(change) }
        .to raise_error(RuntimeError, /non-public registry .*checksum does not match/m)
      expect(downloader.downloaded).to be_empty
    end

    it "fetches each Git revision from the repository that recorded it" do
      downloader = FakeDownloader.new
      change = DependencyChange.new(
        ecosystem: "yarn", name: "widget", old_version: "aaa111", new_version: "bbb222",
        source: "git",
        old_locator: "git+https://github.com/example/widget.git#aaa111",
        new_locator: "git+https://github.com/someone/widget-fork.git#bbb222",
        direct: true, lockfiles: ["yarn.lock"]
      )

      retriever(downloader).retrieve(change)

      expect(downloader.downloaded).to eq(
        [
          "https://codeload.github.com/example/widget/tar.gz/aaa111",
          "https://codeload.github.com/someone/widget-fork/tar.gz/bbb222",
        ]
      )
    end

    it "falls back to the other locator when one side records no repository" do
      downloader = FakeDownloader.new
      change = DependencyChange.new(
        ecosystem: "bundler", name: "widget", old_version: "aaa111", new_version: "bbb222",
        source: "git", old_locator: nil,
        new_locator: "https://github.com/example/widget.git",
        direct: true, lockfiles: ["Gemfile.lock"]
      )

      retriever(downloader).retrieve(change)

      expect(downloader.downloaded).to eq(
        [
          "https://codeload.github.com/example/widget/tar.gz/aaa111",
          "https://codeload.github.com/example/widget/tar.gz/bbb222",
        ]
      )
    end

    it "resolves the repository and revision from a yarn codeload locator" do
      retriever = described_class.new
      locator = "https://codeload.github.com/example/git-package/tar.gz/abc123"

      expect(retriever.send(:github_repository, locator)).to eq("example/git-package")
    end

    it "resolves the repository from a git+ssh style locator" do
      retriever = described_class.new
      locator = "git+https://github.com/example/git-package.git#abc123"

      expect(retriever.send(:github_repository, locator)).to eq("example/git-package")
    end
  end

  describe GitSnapshot do
    def git(directory, *args)
      stdout, stderr, status = Open3.capture3("git", *args, chdir: directory)
      raise "git #{args.join(" ")} failed: #{stderr}" unless status.success?

      stdout
    end

    it "resolves the merge base and reads the old side from it" do
      Dir.mktmpdir do |directory|
        git(directory, "init", "--initial-branch", "main", ".")
        git(directory, "config", "user.email", "test@example.com")
        git(directory, "config", "user.name", "Test")

        File.write(File.join(directory, "Gemfile.lock"), "fork point\n")
        git(directory, "add", ".")
        git(directory, "commit", "-m", "fork point")
        fork_point = git(directory, "rev-parse", "HEAD").strip

        git(directory, "checkout", "-b", "feature")
        File.write(File.join(directory, "Gemfile.lock"), "head\n")
        git(directory, "commit", "-am", "head")
        head_sha = git(directory, "rev-parse", "HEAD").strip

        git(directory, "checkout", "main")
        File.write(File.join(directory, "Gemfile.lock"), "base tip\n")
        git(directory, "commit", "-am", "base tip")
        base_sha = git(directory, "rev-parse", "HEAD").strip

        snapshot = described_class.new(workspace: directory, base_sha: base_sha, head_sha: head_sha)

        expect(snapshot.merge_base_sha).to eq(fork_point)
        expect(snapshot.read(snapshot.merge_base_sha, "Gemfile.lock")).to eq("fork point\n")
        expect(snapshot.changed_dependency_files).to eq(["Gemfile.lock"])
      end
    end

    it "matches dependency files on whole path segments" do
      Dir.mktmpdir do |directory|
        git(directory, "init", "--initial-branch", "main", ".")
        git(directory, "config", "user.email", "test@example.com")
        git(directory, "config", "user.name", "Test")

        {
          "package.json" => "{}",
          "components/widget/package.json" => "{}",
          "docs/my-package.json" => "{}",
          "config/custom-Gemfile" => "",
          "Gemfile" => "",
          "widget.gemspec" => "",
        }.each do |path, content|
          FileUtils.mkdir_p(File.join(directory, File.dirname(path)))
          File.write(File.join(directory, path), content)
        end
        git(directory, "add", ".")
        git(directory, "commit", "-m", "fixtures")
        head_sha = git(directory, "rev-parse", "HEAD").strip

        snapshot = described_class.new(workspace: directory, base_sha: head_sha, head_sha: head_sha)

        expect(snapshot.paths_at(head_sha, "package.json"))
          .to contain_exactly("package.json", "components/widget/package.json")
        expect(snapshot.paths_at(head_sha, "Gemfile")).to eq(["Gemfile"])
        expect(snapshot.paths_at(head_sha, ".gemspec")).to eq(["widget.gemspec"])
      end
    end
  end

  describe SafeTarExtractor do
    def build_tar_gz(path, entry_name)
      Zlib::GzipWriter.open(path) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          tar.add_file_simple(entry_name, 0o644, 4) { |file| file.write("test") }
        end
      end
    end

    it "extracts regular files" do
      Dir.mktmpdir do |directory|
        archive = File.join(directory, "safe.tgz")
        target = File.join(directory, "target")
        build_tar_gz(archive, "package/lib/example.rb")

        described_class.new.extract_gzip(archive, target)
        expect(File.read(File.join(target, "package/lib/example.rb"))).to eq("test")
      end
    end

    it "extracts archives that open with a pax global header" do
      Dir.mktmpdir do |directory|
        archive = File.join(directory, "codeload.tgz")
        target = File.join(directory, "target")
        payload = "52 comment=0000000000000000000000000000000000000000\n"

        Zlib::GzipWriter.open(archive) do |gzip|
          header = Gem::Package::TarHeader.new(
            name: "pax_global_header", mode: 0o644, size: payload.bytesize,
            prefix: "", typeflag: "g", mtime: 0, uid: 0, gid: 0
          )
          gzip.write(header.to_s)
          gzip.write(payload)
          gzip.write("\0" * (512 - (payload.bytesize % 512)))
          Gem::Package::TarWriter.new(gzip) do |tar|
            tar.add_file_simple("widget-abc123/lib/example.rb", 0o644, 4) { |file| file.write("test") }
          end
        end

        described_class.new.extract_gzip(archive, target)
        expect(File.read(File.join(target, "widget-abc123/lib/example.rb"))).to eq("test")
      end
    end

    it "rejects symlink entries" do
      Dir.mktmpdir do |directory|
        archive = File.join(directory, "symlink.tgz")
        Zlib::GzipWriter.open(archive) do |gzip|
          Gem::Package::TarWriter.new(gzip) do |tar|
            tar.add_symlink("package/escape", "/etc/passwd", 0o777)
          end
        end

        expect do
          described_class.new.extract_gzip(archive, File.join(directory, "target"))
        end.to raise_error(RuntimeError, /unsupported link or device entry/)
      end
    end

    it "rejects an archive that expands past the size limit" do
      stub_const("#{described_class}::MAX_EXTRACTED_BYTES", 512)

      Dir.mktmpdir do |directory|
        archive = File.join(directory, "bomb.tgz")
        Zlib::GzipWriter.open(archive) do |gzip|
          Gem::Package::TarWriter.new(gzip) do |tar|
            tar.add_file_simple("package/big.bin", 0o644, 1024) { |file| file.write("z" * 1024) }
          end
        end

        expect do
          described_class.new.extract_gzip(archive, File.join(directory, "target"))
        end.to raise_error(RuntimeError, /expands beyond/)
      end
    end

    it "rejects an archive with more files than the limit" do
      stub_const("#{described_class}::MAX_FILES", 2)

      Dir.mktmpdir do |directory|
        archive = File.join(directory, "many.tgz")
        Zlib::GzipWriter.open(archive) do |gzip|
          Gem::Package::TarWriter.new(gzip) do |tar|
            3.times { |index| tar.add_file_simple("package/#{index}.txt", 0o644, 1) { |f| f.write("x") } }
          end
        end

        expect do
          described_class.new.extract_gzip(archive, File.join(directory, "target"))
        end.to raise_error(RuntimeError, /more than 2 files/)
      end
    end

    it "rejects path traversal" do
      Dir.mktmpdir do |directory|
        archive = File.join(directory, "unsafe.tgz")
        build_tar_gz(archive, "../escape.txt")

        expect do
          described_class.new.extract_gzip(archive, File.join(directory, "target"))
        end.to raise_error(RuntimeError, /Unsafe archive path/)
      end
    end
  end

  describe SourceDiffBuilder do
    it "ranks colocated test files below runtime source" do
      builder = described_class.new
      ranked = lambda { |path| builder.send(:priority, path) }

      expect(ranked.call("app/pb_kits/playbook/pb_avatar/avatar.test.js")).to eq(2)
      expect(ranked.call("app/pb_kits/playbook/pb_card/card.test.jsx")).to eq(2)
      expect(ranked.call("lib/widget_spec.rb")).to eq(2)
      expect(ranked.call("src/foo-test.ts")).to eq(2)

      # Names that merely contain "test" are still runtime source.
      expect(ranked.call("app/latest.js")).to eq(1)
      expect(ranked.call("lib/contest.rb")).to eq(1)
      expect(ranked.call("app/pb_kits/playbook/pb_card/card.rb")).to eq(1)
    end

    it "orders runtime source ahead of a colocated test" do
      Dir.mktmpdir do |directory|
        old_root = File.join(directory, "old")
        new_root = File.join(directory, "new")
        FileUtils.mkdir_p([old_root, new_root])
        %w[card.rb card.test.jsx].each do |name|
          File.write(File.join(old_root, name), "old\n")
          File.write(File.join(new_root, name), "new\n")
        end

        expect(described_class.new.build(old_root, new_root).map(&:path))
          .to eq(["card.rb", "card.test.jsx"])
      end
    end

    it "prioritizes changelogs and emits unified source diffs" do
      Dir.mktmpdir do |directory|
        old_root = File.join(directory, "old")
        new_root = File.join(directory, "new")
        FileUtils.mkdir_p([File.join(old_root, "lib"), File.join(new_root, "lib")])
        File.write(File.join(old_root, "CHANGELOG.md"), "old\n")
        File.write(File.join(new_root, "CHANGELOG.md"), "new\n")
        File.write(File.join(old_root, "lib/example.rb"), "old\n")
        File.write(File.join(new_root, "lib/example.rb"), "new\n")

        chunks = described_class.new.build(old_root, new_root)
        expect(chunks.map(&:path)).to eq(["CHANGELOG.md", "lib/example.rb"])
        expect(chunks.first.diff).to include("a/CHANGELOG.md", "b/CHANGELOG.md")
      end
    end
  end

  describe DependencyDeltaGenerator do
    let(:change) do
      DependencyChange.new(
        ecosystem: "bundler",
        name: "example",
        old_version: "1.0.0",
        new_version: "2.0.0",
        source: "rubygems",
        old_locator: "https://rubygems.org/",
        new_locator: "https://rubygems.org/",
        direct: true,
        lockfiles: ["Gemfile.lock"]
      )
    end

    it "records retrieval failures as warnings without raising" do
      retriever = double("retriever")
      allow(retriever).to receive(:retrieve).and_raise("not public")

      result = described_class.new(changes: [change], retriever: retriever).generate
      entry = result.dig(:manifest, "dependencies", 0)
      expect(entry).to include("status" => "unavailable", "warnings" => ["not public"])
      expect(result.dig(:manifest, "warning_count")).to eq(1)
    end

    it "reports lockfiles it could not analyze without failing generation" do
      problem = DependencyChangeDetector::LockfileProblem.new(
        path: "components/broken/Gemfile.lock",
        message: "Unable to parse components/broken/Gemfile.lock: boom"
      )

      result = described_class.new(changes: [], problems: [problem]).generate

      expect(result.dig(:manifest, "lockfile_warnings")).to eq(
        [{ "lockfile" => "components/broken/Gemfile.lock", "warning" => problem.message }]
      )
      expect(result.dig(:manifest, "warning_count")).to eq(1)
    end

    it "does not mark a dependency truncated when only the shared artifact budget ran out" do
      big = DependencyChange.new(
        ecosystem: "bundler", name: "aaa-big", old_version: "1.0.0", new_version: "2.0.0",
        source: "rubygems", old_locator: "https://rubygems.org/",
        new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
      )
      small = DependencyChange.new(
        ecosystem: "bundler", name: "zzz-small", old_version: "1.0.0", new_version: "2.0.0",
        source: "rubygems", old_locator: "https://rubygems.org/",
        new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
      )
      # 100 KiB chunks pack the 10 MiB artifact budget to within ~40 KiB, so the 50 KiB
      # chunk that follows no longer fits the artifact -- while still fitting the
      # 100 KiB per-dependency and 500 KiB total provider-context budgets.
      retriever = double("retriever")
      allow(retriever).to receive(:retrieve) do |change|
        if change.name == "aaa-big"
          Array.new(110) { |index| SourceDiff.new(path: "big/#{index}.rb", diff: "x" * (100 * 1024)) }
        else
          [SourceDiff.new(path: "small.rb", diff: "y" * (50 * 1024))]
        end
      end

      result = described_class.new(changes: [big, small], retriever: retriever).generate
      entries = result.dig(:manifest, "dependencies").each_with_object({}) do |entry, index|
        index[entry.fetch("name")] = entry
      end

      expect(entries.fetch("zzz-small").fetch("status")).to eq("retrieved")
      expect(entries.fetch("zzz-small").fetch("warnings").join).to include("artifact only")
      expect(result.dig(:manifest, "warning_count")).to eq(1)
    end

    it "links a gem and an npm package released together as one upstream release" do
      gem_change = DependencyChange.new(
        ecosystem: "bundler", name: "playbook_ui", old_version: "14.10.0", new_version: "14.11.0",
        source: "rubygems", old_locator: "https://rubygems.org/",
        new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
      )
      npm_change = DependencyChange.new(
        ecosystem: "yarn", name: "playbook-ui", old_version: "14.10.0", new_version: "14.11.0",
        source: "npm", old_locator: "https://registry.npmjs.org/playbook-ui/-/playbook-ui-14.10.0.tgz",
        new_locator: "https://registry.npmjs.org/playbook-ui/-/playbook-ui-14.11.0.tgz",
        direct: true, lockfiles: ["yarn.lock"]
      )
      retriever = double("retriever", retrieve: [SourceDiff.new(path: "CHANGELOG.md", diff: "x\n")])

      result = described_class.new(changes: [gem_change, npm_change], retriever: retriever).generate
      entries = result.dig(:manifest, "dependencies").each_with_object({}) do |entry, index|
        index[entry.fetch("name")] = entry
      end

      expect(entries.fetch("playbook_ui").fetch("related")).to eq(["yarn:playbook-ui"])
      expect(entries.fetch("playbook-ui").fetch("related")).to eq(["bundler:playbook_ui"])
      # Both deltas are still retrieved -- the published artifacts differ.
      expect(entries.values.map { |entry| entry.fetch("status") }).to eq(%w[retrieved retrieved])
      expect(result.fetch(:context)).to include("Same upstream release as yarn:playbook-ui.")
    end

    it "does not link packages whose versions moved differently" do
      gem_change = DependencyChange.new(
        ecosystem: "bundler", name: "widget", old_version: "1.0.0", new_version: "2.0.0",
        source: "rubygems", old_locator: "https://rubygems.org/",
        new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
      )
      npm_change = DependencyChange.new(
        ecosystem: "yarn", name: "widget", old_version: "1.0.0", new_version: "3.0.0",
        source: "npm", old_locator: "https://registry.npmjs.org/widget/-/widget-1.0.0.tgz",
        new_locator: "https://registry.npmjs.org/widget/-/widget-3.0.0.tgz",
        direct: true, lockfiles: ["yarn.lock"]
      )
      retriever = double("retriever", retrieve: [SourceDiff.new(path: "CHANGELOG.md", diff: "x\n")])

      result = described_class.new(changes: [gem_change, npm_change], retriever: retriever).generate

      expect(result.dig(:manifest, "dependencies").map { |entry| entry.fetch("related") }).to eq([[], []])
    end

    it "names every file it omitted from the provider context" do
      diffs = [
        SourceDiff.new(path: "CHANGELOG.md", diff: "c" * 1024),
        SourceDiff.new(path: "lib/huge.rb", diff: "h" * (described_class::CONTEXT_PER_DEPENDENCY_LIMIT + 1)),
        SourceDiff.new(path: "lib/small.rb", diff: "s" * 1024),
      ]
      result = described_class.new(changes: [change], retriever: double("r", retrieve: diffs)).generate
      entry = result.dig(:manifest, "dependencies", 0)

      expect(entry).to include(
        "status" => "truncated",
        "changed_files" => 3,
        "context_files" => 2,
        "omitted_from_context" => ["lib/huge.rb"]
      )
      expect(entry.fetch("warnings").join).to include("1 file diffs were omitted")
    end

    it "records the whole file list when the total context budget drops a dependency" do
      # 60 KiB fits the per-dependency budget but not the sliver left in the total.
      diffs = [
        SourceDiff.new(path: "a.rb", diff: "a" * (30 * 1024)),
        SourceDiff.new(path: "b.rb", diff: "b" * (30 * 1024)),
      ]
      # Each filler contributes ~99 KiB, just under the per-dependency cap, so six of
      # them exhaust the 500 KiB total before the dependency under test is reached.
      fillers = Array.new(6) do |index|
        DependencyChange.new(
          ecosystem: "bundler", name: "aaa-filler-#{index}", old_version: "1.0.0",
          new_version: "2.0.0", source: "rubygems", old_locator: "https://rubygems.org/",
          new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
        )
      end
      retriever = double("retriever")
      allow(retriever).to receive(:retrieve) do |candidate|
        if candidate.name.start_with?("aaa-filler")
          [SourceDiff.new(path: "filler.rb", diff: "f" * (99 * 1024))]
        else
          diffs
        end
      end

      result = described_class.new(changes: fillers + [change], retriever: retriever).generate
      entry = result.dig(:manifest, "dependencies").find { |candidate| candidate.fetch("name") == "example" }

      expect(entry).to include(
        "status" => "truncated",
        "context_files" => 0,
        "omitted_from_context" => ["a.rb", "b.rb"]
      )
      expect(entry.fetch("warnings").join).to include("total limit")
    end

    it "caps provider context and marks truncation" do
      retriever = double(
        "retriever",
        retrieve: [
          SourceDiff.new(
            path: "oversized.rb",
            diff: "x" * (described_class::CONTEXT_PER_DEPENDENCY_LIMIT + 1)
          ),
        ]
      )
      result = described_class.new(changes: [change], retriever: retriever).generate
      expect(result.dig(:manifest, "dependencies", 0, "status")).to eq("truncated")
      expect(result.fetch(:context).bytesize).to be <= described_class::CONTEXT_TOTAL_LIMIT
    end
  end
end
