require_relative "../../spec_helper"
require "test_plan/dependency_delta"

require "set"

RSpec.describe TestPlan::DependencyDelta::YarnChangeDetector do
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

  it "reports a dependency that moved from a Git locator to npm" do
    old_lock = <<~LOCK
      moving@github:example/moving#aaaaaaa:
        version "1.0.0"
        resolved "https://codeload.github.com/example/moving/tar.gz/aaaaaaa"
    LOCK
    new_lock = <<~LOCK
      moving@^2.0.0:
        version "2.0.0"
        resolved "https://registry.npmjs.org/moving/-/moving-2.0.0.tgz"
    LOCK

    changes = described_class.new.detect(
      path: "yarn.lock", old_content: old_lock, new_content: new_lock,
      direct_names: Set["moving"], workspace_names: Set.new
    )

    # version_changes skips any pair with a Git side and git_changes pairs only Git with
    # Git, so this used to fall through both and report nothing at all.
    expect(changes.map(&:source)).to eq(["mixed"])
    expect(changes.first).to have_attributes(old_version: "aaaaaaa", new_version: "2.0.0")
  end

  it "does not call a raise a transition when one name has both kinds of selector" do
    old_lock = <<~LOCK
      mixed@^1.0.0:
        version "1.0.0"
        resolved "https://registry.npmjs.org/mixed/-/mixed-1.0.0.tgz"
      mixed@github:example/mixed#aaaaaaa:
        version "9.9.9"
        resolved "https://codeload.github.com/example/mixed/tar.gz/aaaaaaa"
    LOCK
    new_lock = <<~LOCK
      mixed@^2.0.0:
        version "2.0.0"
        resolved "https://registry.npmjs.org/mixed/-/mixed-2.0.0.tgz"
    LOCK

    changes = described_class.new.detect(
      path: "yarn.lock", old_content: old_lock, new_content: new_lock,
      direct_names: Set["mixed"], workspace_names: Set.new
    )

    # The npm raise is real; the Git selector merely going away is not a transition, and
    # reporting one would have added a second change and a spurious warning.
    expect(changes.map(&:source)).to eq(["npm"])
    expect(changes.first).to have_attributes(old_version: "1.0.0", new_version: "2.0.0")
  end

  it "reports a dependency that moved from npm to a Git locator" do
    old_lock = <<~LOCK
      moving@^1.0.0:
        version "1.0.0"
        resolved "https://registry.npmjs.org/moving/-/moving-1.0.0.tgz"
    LOCK
    new_lock = <<~LOCK
      moving@github:example/moving#bbbbbbb:
        version "2.0.0"
        resolved "https://codeload.github.com/example/moving/tar.gz/bbbbbbb"
    LOCK

    changes = described_class.new.detect(
      path: "yarn.lock", old_content: old_lock, new_content: new_lock,
      direct_names: Set["moving"], workspace_names: Set.new
    )

    expect(changes.map(&:source)).to eq(["mixed"])
    expect(changes.first).to have_attributes(old_version: "1.0.0", new_version: "bbbbbbb")
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
