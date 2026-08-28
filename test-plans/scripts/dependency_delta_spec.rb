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
        expect(chunks.first).to include("a/CHANGELOG.md", "b/CHANGELOG.md")
        expect(chunks.last).to include("a/lib/example.rb", "b/lib/example.rb")
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

    it "caps provider context and marks truncation" do
      retriever = double("retriever", retrieve: ["x" * (described_class::CONTEXT_PER_DEPENDENCY_LIMIT + 1)])
      result = described_class.new(changes: [change], retriever: retriever).generate
      expect(result.dig(:manifest, "dependencies", 0, "status")).to eq("truncated")
      expect(result.fetch(:context).bytesize).to be <= described_class::CONTEXT_TOTAL_LIMIT
    end
  end
end
