require_relative "../../spec_helper"
require "test_plan/dependency_delta"

require "json"

RSpec.describe TestPlan::DependencyDelta::ChangelogSource do
  # Stands in for the network: keyed by URL, values are file bodies. Anything not
  # listed 404s, which is how a missing tag or changelog actually presents.
  class FakeChangelogDownloader
    attr_reader :requested

    def initialize(bodies)
      @bodies = bodies
      @requested = []
    end

    def download(url, destination)
      @requested << url
      body = @bodies[url] or raise "Dependency download failed (404): #{url}"
      File.write(destination, body)
      destination
    end
  end

  def npm_change(name: "playbook-ui", old_version: "17.0.0", new_version: "17.1.0",
                 locator: nil, integrity: nil, old_integrity: nil)
    TestPlan::DependencyDelta::Change.new(
      ecosystem: "yarn", name: name, old_version: old_version, new_version: new_version,
      source: "npm",
      old_locator: locator || "https://registry.npmjs.org/#{name}/-/#{name}-#{old_version}.tgz",
      new_locator: locator || "https://registry.npmjs.org/#{name}/-/#{name}-#{new_version}.tgz",
      old_integrity: old_integrity, new_integrity: integrity,
      direct: true, lockfiles: ["yarn.lock"]
    )
  end

  def gem_change(name: "rack")
    TestPlan::DependencyDelta::Change.new(
      ecosystem: "bundler", name: name, old_version: "3.1.7", new_version: "3.1.8",
      source: "rubygems", old_locator: "https://rubygems.org/",
      new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
    )
  end

  # Both versions are looked up: the changelog diff starts at the old version's tag, so
  # the old side has to be shown to be this package too.
  let(:npm_metadata) do
    {
      "https://registry.npmjs.org/playbook-ui/17.1.0" => JSON.generate(
        "dist" => { "tarball" => "https://registry.npmjs.org/x.tgz", "integrity" => "sha512-public==" },
        "repository" => {
          "type" => "git",
          "url" => "git+ssh://git@github.com/powerhome/playbook.git",
          "directory" => "playbook",
        }
      ),
      "https://registry.npmjs.org/playbook-ui/17.0.0" => JSON.generate(
        "dist" => { "tarball" => "https://registry.npmjs.org/y.tgz", "integrity" => "sha512-public-old==" }
      ),
    }
  end

  def raw(ref, body, path: "playbook/CHANGELOG.md", repo: "powerhome/playbook")
    { "https://raw.githubusercontent.com/#{repo}/#{ref}/#{path}" => body }
  end

  it "diffs the repository changelog between the old tag and the default branch" do
    downloader = FakeChangelogDownloader.new(
      npm_metadata
        .merge(raw("17.0.0", "# 16.12.0\nolder notes\n"))
        .merge(raw("HEAD", "# 17.1.0\nnew notes\n\n# 16.12.0\nolder notes\n"))
    )

    diffs = described_class.new(downloader: downloader).diffs_for(npm_change)

    expect(diffs.length).to eq(1)
    expect(diffs.first.path).to eq("playbook/CHANGELOG.md")
    expect(diffs.first.priority).to eq(TestPlan::DependencyDelta::SourceDiffBuilder::PRIORITY_CHANGELOG)
    expect(diffs.first.diff).to include("+# 17.1.0", "+new notes")
  end

  it "stops at the upgraded-to tag when it already describes that release" do
    downloader = FakeChangelogDownloader.new(
      npm_metadata
        .merge(raw("17.0.0", "# 16.12.0\n"))
        .merge(raw("17.1.0", "# 17.1.0\nthe upgrade\n\n# 16.12.0\n"))
        .merge(raw("HEAD", "# 18.0.0\nreleased since\n\n# 17.1.0\nthe upgrade\n\n# 16.12.0\n"))
    )

    diff = described_class.new(downloader: downloader).diffs_for(npm_change).first.diff

    # Bounded by the upgrade: a release made since is not part of it.
    expect(diff).to include("+the upgrade")
    expect(diff).not_to include("released since")
    expect(diff).not_to include("read from the default branch")
  end

  it "falls back to the default branch when the tag predates its own notes" do
    # playbook's 17.1.0 tag still describes 17.0.0 as the newest release, because the
    # changelog is generated after tagging.
    downloader = FakeChangelogDownloader.new(
      npm_metadata
        .merge(raw("17.0.0", "# 16.12.0\n"))
        .merge(raw("17.1.0", "# 17.0.0\n\n# 16.12.0\n"))
        .merge(raw("HEAD", "# 17.1.0\nthe upgrade\n\n# 17.0.0\n\n# 16.12.0\n"))
    )

    diff = described_class.new(downloader: downloader).diffs_for(npm_change).first.diff

    expect(diff).to include("+the upgrade")
    # The default branch can carry later releases too, so the notes say so.
    expect(diff).to start_with("[These notes were read from the default branch")
    expect(diff).to include("later than 17.1.0")
  end

  it "falls back to a v-prefixed tag" do
    downloader = FakeChangelogDownloader.new(
      npm_metadata
        .merge(raw("v17.0.0", "old\n"))
        .merge(raw("HEAD", "new\n"))
    )

    expect(described_class.new(downloader: downloader).diffs_for(npm_change).length).to eq(1)
  end

  it "resolves a gem's repository from its rubygems metadata" do
    downloader = FakeChangelogDownloader.new(
      {
        "https://rubygems.org/api/v1/gems/rack.json" => JSON.generate(
          "source_code_uri" => "https://github.com/rack/rack"
        ),
      }
        .merge(raw("3.1.7", "old\n", path: "CHANGELOG.md", repo: "rack/rack"))
        .merge(raw("HEAD", "new\n", path: "CHANGELOG.md", repo: "rack/rack"))
    )

    diffs = described_class.new(downloader: downloader).diffs_for(gem_change)

    expect(diffs.first.path).to eq("CHANGELOG.md")
  end

  it "takes both repository and path from a gem's changelog_uri" do
    # playbook_ui keeps its changelog under playbook/, not at the repository root, so
    # the URI has to supply the path as well.
    downloader = FakeChangelogDownloader.new(
      {
        "https://rubygems.org/api/v1/gems/playbook_ui.json" => JSON.generate(
          "source_code_uri" => "https://github.com/powerhome/playbook",
          "changelog_uri" => "https://github.com/powerhome/playbook/blob/master/playbook/CHANGELOG.md"
        ),
      }
        .merge(raw("17.0.0", "old\n"))
        .merge(raw("HEAD", "new\n"))
    )
    change = TestPlan::DependencyDelta::Change.new(
      ecosystem: "bundler", name: "playbook_ui", old_version: "17.0.0", new_version: "17.1.0",
      source: "rubygems", old_locator: "https://rubygems.org/",
      new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
    )

    diffs = described_class.new(downloader: downloader).diffs_for(change)

    expect(diffs.first.path).to eq("playbook/CHANGELOG.md")
    expect(downloader.requested).not_to include(
      "https://raw.githubusercontent.com/powerhome/playbook/17.0.0/CHANGELOG.md"
    )
  end

  it "reads the changelog of a proxied package whose checksum matches the public one" do
    downloader = FakeChangelogDownloader.new(
      npm_metadata.merge(raw("17.0.0", "old\n")).merge(raw("HEAD", "new\n"))
    )
    change = npm_change(
      locator: "https://npm.powerapp.cloud/playbook-ui/-/playbook-ui-17.1.0.tgz",
      integrity: "sha512-public==", old_integrity: "sha512-public-old=="
    )

    expect(described_class.new(downloader: downloader).diffs_for(change).length).to eq(1)
  end

  it "refuses when only the new side proves to be the public package" do
    # Source retrieval rejects the old side, and a changelog survives a refused
    # download, so the public project's history would stand in for the private old
    # version's release notes.
    downloader = FakeChangelogDownloader.new(
      npm_metadata.merge(raw("17.0.0", "old\n")).merge(raw("HEAD", "new\n"))
    )
    change = npm_change(
      locator: "https://npm.powerapp.cloud/playbook-ui/-/playbook-ui-17.1.0.tgz",
      integrity: "sha512-public==", old_integrity: "sha512-was-private=="
    )

    expect(described_class.new(downloader: downloader).diffs_for(change)).to be_empty
  end

  it "refuses the changelog of a private package that only shares a public name" do
    # Source retrieval rejects this package for the same reason, and a changelog
    # survives a refused download -- so without this check the provider would be handed
    # an unrelated project's release notes precisely when it has nothing else.
    downloader = FakeChangelogDownloader.new(
      npm_metadata.merge(raw("17.0.0", "old\n")).merge(raw("HEAD", "new\n"))
    )
    change = npm_change(
      locator: "https://npm.powerapp.cloud/playbook-ui/-/playbook-ui-17.1.0.tgz",
      integrity: "sha512-different=="
    )

    expect(described_class.new(downloader: downloader).diffs_for(change)).to be_empty
  end

  it "refuses the changelog of a gem resolved from a private remote" do
    downloader = FakeChangelogDownloader.new({})
    change = TestPlan::DependencyDelta::Change.new(
      ecosystem: "bundler", name: "rack", old_version: "3.1.7", new_version: "3.1.8",
      source: "rubygems", old_locator: "https://gems.powerapp.cloud/",
      new_locator: "https://gems.powerapp.cloud/", direct: true, lockfiles: ["Gemfile.lock"]
    )

    expect(described_class.new(downloader: downloader).diffs_for(change)).to be_empty
    expect(downloader.requested).to be_empty
  end

  it "reads a Git-pinned upgrade at its revision, not at the default branch" do
    downloader = FakeChangelogDownloader.new(
      raw("aaaaaaa", "old notes\n", path: "CHANGELOG.md", repo: "example/widget")
        .merge(raw("bbbbbbb", "notes through bbbbbbb\n", path: "CHANGELOG.md", repo: "example/widget"))
        .merge(raw("HEAD", "notes for commits this pin does not include\n",
                   path: "CHANGELOG.md", repo: "example/widget"))
    )
    change = TestPlan::DependencyDelta::Change.new(
      ecosystem: "yarn", name: "widget", old_version: "aaaaaaa", new_version: "bbbbbbb",
      source: "git", old_locator: "git+https://github.com/example/widget.git#aaaaaaa",
      new_locator: "git+https://github.com/example/widget.git#bbbbbbb",
      direct: true, lockfiles: ["yarn.lock"]
    )

    # The lockfile pins an exact revision, so reading past it describes commits the
    # dependency does not contain.
    diff = described_class.new(downloader: downloader).diffs_for(change).first.diff
    expect(diff).to include("+notes through bbbbbbb")
    expect(diff).not_to include("this pin does not include")
  end

  it "returns nothing when the package records no repository" do
    downloader = FakeChangelogDownloader.new(
      "https://registry.npmjs.org/playbook-ui/17.1.0" => JSON.generate(
        "dist" => { "integrity" => "sha512-public==" }, "name" => "playbook-ui"
      )
    )

    expect(described_class.new(downloader: downloader).diffs_for(npm_change)).to be_empty
  end

  it "returns nothing when no changelog exists at the old tag" do
    downloader = FakeChangelogDownloader.new(npm_metadata.merge(raw("HEAD", "new\n")))

    expect(described_class.new(downloader: downloader).diffs_for(npm_change)).to be_empty
  end

  it "returns nothing when the changelog did not change" do
    downloader = FakeChangelogDownloader.new(
      npm_metadata.merge(raw("17.0.0", "same\n")).merge(raw("HEAD", "same\n"))
    )

    expect(described_class.new(downloader: downloader).diffs_for(npm_change)).to be_empty
  end

  it "caps an oversized diff instead of letting it be dropped whole" do
    downloader = FakeChangelogDownloader.new(
      npm_metadata
        .merge(raw("17.0.0", "old\n"))
        .merge(raw("HEAD", Array.new(20_000) { |i| "line #{i}" }.join("\n")))
    )

    source_diff = described_class.new(downloader: downloader).diffs_for(npm_change).first

    # The provider sees a capped diff; the artifact keeps the whole thing, so the
    # notice's pointer to the artifact is true.
    expect(source_diff.context_text.bytesize)
      .to be <= described_class::MAX_DIFF_BYTES + described_class::TRUNCATION_NOTICE.bytesize
    expect(source_diff.context_text).to end_with(described_class::TRUNCATION_NOTICE)
    expect(source_diff.artifact_text.bytesize).to be > described_class::MAX_DIFF_BYTES
    expect(source_diff.artifact_text).not_to include(described_class::TRUNCATION_NOTICE)
  end

  it "never raises when the registry itself is unreachable" do
    downloader = FakeChangelogDownloader.new({})

    expect { described_class.new(downloader: downloader).diffs_for(npm_change) }.not_to raise_error
  end
end
