require_relative "../../spec_helper"
require "test_plan/dependency_delta"

require "fileutils"
require "tmpdir"

RSpec.describe TestPlan::DependencyDelta::SourceDiffBuilder do
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

  it "classifies build output as generated whatever its filename suggests" do
    builder = described_class.new
    ranked = lambda { |path| builder.send(:priority, path) }

    # These used to rank as test and documentation, so generated? was false and a linked
    # release's bundles reached the provider despite the exclusion.
    expect(ranked.call("dist/widget.test.js")).to eq(described_class::PRIORITY_GENERATED)
    expect(ranked.call("build/docs/readme.md")).to eq(described_class::PRIORITY_GENERATED)
    expect(ranked.call("node_modules/thing/spec/x.rb")).to eq(described_class::PRIORITY_GENERATED)

    # A changelog shipped inside dist/ is still the release notes.
    expect(ranked.call("dist/CHANGELOG.md")).to eq(described_class::PRIORITY_CHANGELOG)
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

  it "records a binary change instead of dropping it" do
    Dir.mktmpdir do |directory|
      old_root = File.join(directory, "old")
      new_root = File.join(directory, "new")
      FileUtils.mkdir_p([old_root, new_root])
      File.binwrite(File.join(old_root, "icon.png"), "\x89PNG\x00old".b)
      File.binwrite(File.join(new_root, "icon.png"), "\x89PNG\x00new-and-longer".b)
      File.binwrite(File.join(new_root, "added.woff"), "\x00\x01font".b)

      diffs = described_class.new.build(old_root, new_root)

      # A changed icon or font is user-visible; dropping it left nothing in the artifact
      # and nothing in any omission list.
      expect(diffs.map(&:path)).to contain_exactly("icon.png", "added.woff")
      expect(diffs.find { |d| d.path == "icon.png" }.diff).to include("Binary file icon.png changed")
      expect(diffs.find { |d| d.path == "added.woff" }.diff).to include("was added")
    end
  end

  it "leaves an unchanged binary alone" do
    Dir.mktmpdir do |directory|
      old_root = File.join(directory, "old")
      new_root = File.join(directory, "new")
      FileUtils.mkdir_p([old_root, new_root])
      [old_root, new_root].each { |root| File.binwrite(File.join(root, "icon.png"), "\x89PNG\x00".b) }

      expect(described_class.new.build(old_root, new_root)).to be_empty
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
