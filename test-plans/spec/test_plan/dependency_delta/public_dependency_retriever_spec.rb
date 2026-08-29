require_relative "../../spec_helper"
require "test_plan/dependency_delta"

require "fileutils"
require "tmpdir"

RSpec.describe TestPlan::DependencyDelta::PublicRetriever do
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
    TestPlan::DependencyDelta::Change.new(
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
    change = TestPlan::DependencyDelta::Change.new(
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
    change = TestPlan::DependencyDelta::Change.new(
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
    change = TestPlan::DependencyDelta::Change.new(
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
    change = TestPlan::DependencyDelta::Change.new(
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
