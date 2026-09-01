require_relative "../../spec_helper"
require "test_plan/dependency_delta"

RSpec.describe TestPlan::DependencyDelta::VersionSpelling do
  describe ".canonical" do
    it "collapses the RubyGems and npm spellings of one prerelease" do
      expect(described_class.canonical("17.2.0.pre.rc.0"))
        .to eq(described_class.canonical("17.2.0-rc.0"))
      expect(described_class.canonical("17.1.0.pre.alpha.tiptapformatting18903"))
        .to eq(described_class.canonical("17.1.0-alpha.tiptapformatting18903"))
    end

    it "leaves a release version alone" do
      expect(described_class.canonical("17.1.0")).to eq("17.1.0")
    end

    it "keeps distinct prereleases distinct" do
      expect(described_class.canonical("17.2.0.pre.rc.0"))
        .not_to eq(described_class.canonical("17.2.0-rc.1"))
    end

    # A Git revision is a version here too, and RubyGems will not parse one.
    it "compares an unparseable version as written" do
      sha = "00c9eaaf26758a8f62a0733f46d5064dc37f6e0e"
      expect(described_class.canonical(sha)).to eq(sha)
    end
  end

  describe ".spellings" do
    it "offers the hyphenated spelling of a gem prerelease" do
      expect(described_class.spellings("17.2.0.pre.rc.0")).to eq(["17.2.0.pre.rc.0", "17.2.0-rc.0"])
    end

    it "offers one spelling when there is nothing to rewrite" do
      expect(described_class.spellings("17.1.0")).to eq(["17.1.0"])
      expect(described_class.spellings("17.2.0-rc.0")).to eq(["17.2.0-rc.0"])
    end

    # ".pre" with nothing after it names no prerelease to hyphenate, and "17.2.0-" is
    # not a tag anyone publishes.
    it "does not hyphenate a bare pre marker" do
      expect(described_class.spellings("17.2.0.pre")).to eq(["17.2.0.pre"])
    end
  end
end
