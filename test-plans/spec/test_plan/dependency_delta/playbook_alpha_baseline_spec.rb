# frozen_string_literal: true

require_relative "../../spec_helper"
require "test_plan/dependency_delta"

RSpec.describe TestPlan::DependencyDelta::PlaybookAlphaBaseline do
  let(:alpha) { "PLAY3189datepickercloseonselect19522" }
  let(:registry) { "https://registry.yarnpkg.com/playbook-ui/-/playbook-ui-18.1.0-rc.3.tgz" }
  let(:published) { ["playbook_ui", "18.0.0"] }

  # Stands in for the registries: a release answers only if it is listed.
  let(:downloader) do
    published_versions = [published, ["playbook-ui", "18.0.0"]]
    double("downloader").tap do |fake|
      allow(fake).to receive(:rubygems_version) do |name, version|
        raise "Dependency download failed (404)" unless published_versions.include?([name, version])

        {}
      end
      allow(fake).to receive(:npm_dist) do |name, version|
        raise "Dependency download failed (404)" unless published_versions.include?([name, version])

        { "tarball" => "https://registry.npmjs.org/#{name}/-/#{name}-#{version}.tgz", "integrity" => "sha512-base" }
      end
    end
  end

  subject(:baseline) { described_class.new(downloader:) }

  def change(name: "playbook_ui", source: "rubygems", old_version: "18.1.0.pre.rc.3",
             new_version: "18.0.0.pre.alpha.#{alpha}", **overrides)
    TestPlan::DependencyDelta::Change.new(
      ecosystem: source == "npm" ? "yarn" : "bundler",
      name:,
      old_version:,
      new_version:,
      source:,
      old_locator: "https://rubygems.org/",
      new_locator: "https://rubygems.org/",
      old_integrity: "sha512-installed",
      direct: true,
      lockfiles: ["Gemfile.lock"],
      **overrides
    )
  end

  it "reads an alpha below the installed release against the release it was built from" do
    resolved = baseline.resolve(change)

    expect(resolved).to have_attributes(
      old_version: "18.0.0",
      new_version: "18.0.0.pre.alpha.#{alpha}",
      installed_version: "18.1.0.pre.rc.3"
    )
    expect(resolved.to_h).to include("old_version" => "18.0.0", "installed_version" => "18.1.0.pre.rc.3")
  end

  it "does not alter the change it was given" do
    original = change

    baseline.resolve(original)

    expect(original).to have_attributes(old_version: "18.1.0.pre.rc.3", installed_version: nil)
  end

  it "reads the npm half the same way, from the public registry's copy of the release" do
    resolved = baseline.resolve(
      change(name: "playbook-ui", source: "npm", old_version: "18.1.0-rc.3", new_version: "18.0.0-alpha.#{alpha}",
             old_locator: registry)
    )

    expect(resolved).to have_attributes(
      old_version: "18.0.0",
      installed_version: "18.1.0-rc.3",
      old_locator: "https://registry.npmjs.org/playbook-ui/-/playbook-ui-18.0.0.tgz",
      old_integrity: "sha512-base"
    )
  end

  it "leaves the two halves of one release on the same versions" do
    gem = baseline.resolve(change)
    package = baseline.resolve(
      change(name: "playbook-ui", source: "npm", old_version: "18.1.0-rc.3", new_version: "18.0.0-alpha.#{alpha}")
    )

    expect(TestPlan::DependencyDelta::VersionSpelling.canonical(gem.old_version))
      .to eq(TestPlan::DependencyDelta::VersionSpelling.canonical(package.old_version))
  end

  it "leaves an alpha that is above the installed release alone" do
    raised = change(old_version: "17.1.0", new_version: "18.0.0.pre.alpha.#{alpha}")

    expect(baseline.resolve(raised)).to equal(raised)
  end

  it "leaves a release candidate that is below the installed release alone" do
    lowered = change(old_version: "18.1.0.pre.rc.3", new_version: "18.0.1.pre.rc.0")

    expect(baseline.resolve(lowered)).to equal(lowered)
  end

  it "leaves an alpha alone when the installed release is already its base" do
    same = change(old_version: "18.0.0")

    expect(baseline.resolve(same)).to equal(same)
  end

  it "leaves other dependencies alone" do
    other = change(name: "rails", old_version: "8.0.0", new_version: "7.2.0.pre.alpha.1")

    expect(baseline.resolve(other)).to equal(other)
  end

  it "falls back to the installed release when the base release is not published" do
    unpublished = change(new_version: "18.2.0.pre.alpha.#{alpha}")

    expect(baseline.resolve(unpublished)).to equal(unpublished)
  end

  it "falls back for a Git source, which has no release to read against" do
    git = change(source: "git", old_version: "abc123", new_version: "def456")

    expect(baseline.resolve(git)).to equal(git)
  end
end
