require_relative "../../spec_helper"
require "test_plan/dependency_delta/source_diff_builder"

require "fileutils"
require "tmpdir"

describe TestPlan::DependencyDelta::SourceDiffBuilder do
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
