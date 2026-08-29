require_relative "../../spec_helper"
require "test_plan/dependency_delta"

RSpec.describe TestPlan::DependencyDelta::Generator do
  # The real ChangelogSource reaches the network; these specs are about budgeting, so
  # they build generators with it stubbed out. The changelog path has its own specs.
  def generator(**options)
    described_class.new(changelog: double("changelog", diffs_for: []), **options)
  end

  let(:change) do
    TestPlan::DependencyDelta::Change.new(
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

    result = generator(changes: [change], retriever: retriever).generate
    entry = result.dig(:manifest, "dependencies", 0)
    expect(entry).to include("status" => "unavailable", "warnings" => ["not public"])
    expect(result.dig(:manifest, "warning_count")).to eq(1)
  end

  it "keeps the changelog when the package download is refused" do
    changelog = TestPlan::DependencyDelta::SourceDiff.new(
      path: "CHANGELOG.md",
      diff: "--- a/CHANGELOG.md\n+++ b/CHANGELOG.md\n+## 2.0.0 fixed the widget\n",
      priority: TestPlan::DependencyDelta::SourceDiffBuilder::PRIORITY_CHANGELOG
    )
    retriever = double("retriever")
    allow(retriever).to receive(:retrieve).and_raise("resolves to a non-public registry")

    result = described_class.new(
      changes: [change],
      retriever: retriever,
      changelog: double("changelog", diffs_for: [changelog])
    ).generate
    entry = result.dig(:manifest, "dependencies", 0)

    # A package the registry refuses still yields its public release notes, which is
    # the part a tester can act on.
    expect(entry).to include("status" => "retrieved", "context_files" => 1)
    expect(entry.fetch("warnings").join).to include("changelog was still read")
    expect(result.fetch(:context)).to include("fixed the widget")
  end

  it "reports the dependency unavailable when neither package nor changelog resolves" do
    retriever = double("retriever")
    allow(retriever).to receive(:retrieve).and_raise("not public")

    result = generator(changes: [change], retriever: retriever).generate

    expect(result.dig(:manifest, "dependencies", 0)).to include(
      "status" => "unavailable",
      "warnings" => ["not public"]
    )
  end

  it "reports lockfiles it could not analyze without failing generation" do
    problem = TestPlan::DependencyDelta::ChangeDetector::LockfileProblem.new(
      path: "components/broken/Gemfile.lock",
      message: "Unable to parse components/broken/Gemfile.lock: boom"
    )

    result = generator(changes: [], problems: [problem]).generate

    expect(result.dig(:manifest, "lockfile_warnings")).to eq(
      [{ "lockfile" => "components/broken/Gemfile.lock", "warning" => problem.message }]
    )
    expect(result.dig(:manifest, "warning_count")).to eq(1)
  end

  it "does not mark a dependency truncated when only the shared artifact budget ran out" do
    big = TestPlan::DependencyDelta::Change.new(
      ecosystem: "bundler", name: "aaa-big", old_version: "1.0.0", new_version: "2.0.0",
      source: "rubygems", old_locator: "https://rubygems.org/",
      new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
    )
    small = TestPlan::DependencyDelta::Change.new(
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
        Array.new(110) { |index| TestPlan::DependencyDelta::SourceDiff.new(path: "big/#{index}.rb", diff: "x" * (100 * 1024)) }
      else
        [TestPlan::DependencyDelta::SourceDiff.new(path: "small.rb", diff: "y" * (50 * 1024))]
      end
    end

    result = generator(changes: [big, small], retriever: retriever).generate
    entries = result.dig(:manifest, "dependencies").each_with_object({}) do |entry, index|
      index[entry.fetch("name")] = entry
    end

    expect(entries.fetch("zzz-small").fetch("status")).to eq("retrieved")
    expect(entries.fetch("zzz-small").fetch("warnings").join).to include("artifact only")
    expect(result.dig(:manifest, "warning_count")).to eq(1)
  end

  it "links a gem and an npm package released together as one upstream release" do
    gem_change = TestPlan::DependencyDelta::Change.new(
      ecosystem: "bundler", name: "playbook_ui", old_version: "14.10.0", new_version: "14.11.0",
      source: "rubygems", old_locator: "https://rubygems.org/",
      new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
    )
    npm_change = TestPlan::DependencyDelta::Change.new(
      ecosystem: "yarn", name: "playbook-ui", old_version: "14.10.0", new_version: "14.11.0",
      source: "npm", old_locator: "https://registry.npmjs.org/playbook-ui/-/playbook-ui-14.10.0.tgz",
      new_locator: "https://registry.npmjs.org/playbook-ui/-/playbook-ui-14.11.0.tgz",
      direct: true, lockfiles: ["yarn.lock"]
    )
    retriever = double("retriever", retrieve: [TestPlan::DependencyDelta::SourceDiff.new(path: "CHANGELOG.md", diff: "x\n")])

    result = generator(changes: [gem_change, npm_change], retriever: retriever).generate
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
    gem_change = TestPlan::DependencyDelta::Change.new(
      ecosystem: "bundler", name: "widget", old_version: "1.0.0", new_version: "2.0.0",
      source: "rubygems", old_locator: "https://rubygems.org/",
      new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
    )
    npm_change = TestPlan::DependencyDelta::Change.new(
      ecosystem: "yarn", name: "widget", old_version: "1.0.0", new_version: "3.0.0",
      source: "npm", old_locator: "https://registry.npmjs.org/widget/-/widget-1.0.0.tgz",
      new_locator: "https://registry.npmjs.org/widget/-/widget-3.0.0.tgz",
      direct: true, lockfiles: ["yarn.lock"]
    )
    retriever = double("retriever", retrieve: [TestPlan::DependencyDelta::SourceDiff.new(path: "CHANGELOG.md", diff: "x\n")])

    result = generator(changes: [gem_change, npm_change], retriever: retriever).generate

    expect(result.dig(:manifest, "dependencies").map { |entry| entry.fetch("related") }).to eq([[], []])
  end

  it "names every file it omitted from the provider context" do
    diffs = [
      TestPlan::DependencyDelta::SourceDiff.new(path: "CHANGELOG.md", diff: "c" * 1024),
      TestPlan::DependencyDelta::SourceDiff.new(path: "lib/huge.rb", diff: "h" * (described_class::CONTEXT_TOTAL_LIMIT + 1)),
      TestPlan::DependencyDelta::SourceDiff.new(path: "lib/small.rb", diff: "s" * 1024),
    ]
    result = generator(changes: [change], retriever: double("r", retrieve: diffs)).generate
    entry = result.dig(:manifest, "dependencies", 0)

    expect(entry).to include(
      "status" => "truncated",
      "changed_files" => 3,
      "context_files" => 2,
      "omitted_from_context" => ["lib/huge.rb"]
    )
    expect(entry.fetch("warnings").join).to include("1 file diffs were omitted")
  end

  it "gives a lone dependency the whole context budget" do
    # 400 KiB would have been cut to 100 KiB under a fixed per-dependency cap.
    diffs = Array.new(8) { |index| TestPlan::DependencyDelta::SourceDiff.new(path: "lib/#{index}.rb", diff: "x" * (50 * 1024)) }

    result = generator(changes: [change], retriever: double("r", retrieve: diffs)).generate
    entry = result.dig(:manifest, "dependencies", 0)

    expect(entry).to include("status" => "retrieved", "context_files" => 8)
    expect(result.fetch(:context).bytesize).to be <= described_class::CONTEXT_TOTAL_LIMIT
  end

  it "hands an early dependency's unused budget to a later one" do
    small = TestPlan::DependencyDelta::Change.new(
      ecosystem: "bundler", name: "aaa-small", old_version: "1.0.0", new_version: "2.0.0",
      source: "rubygems", old_locator: "https://rubygems.org/",
      new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
    )
    retriever = double("retriever")
    allow(retriever).to receive(:retrieve) do |candidate|
      if candidate.name == "aaa-small"
        [TestPlan::DependencyDelta::SourceDiff.new(path: "tiny.rb", diff: "t" * 1024)]
      else
        # 400 KiB: more than an even two-way split would allow.
        Array.new(8) { |index| TestPlan::DependencyDelta::SourceDiff.new(path: "lib/#{index}.rb", diff: "x" * (50 * 1024)) }
      end
    end

    result = generator(changes: [small, change], retriever: retriever).generate
    entry = result.dig(:manifest, "dependencies").find { |candidate| candidate.fetch("name") == "example" }

    expect(entry).to include("status" => "retrieved", "context_files" => 8)
  end

  it "spends the budget on the dependencies sorted first and drops the tail" do
    changes = Array.new(30) do |index|
      TestPlan::DependencyDelta::Change.new(
        ecosystem: "bundler", name: format("gem-%02d", index), old_version: "1.0.0",
        new_version: "2.0.0", source: "rubygems", old_locator: "https://rubygems.org/",
        new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
      )
    end
    retriever = double("retriever")
    allow(retriever).to receive(:retrieve) do |candidate|
      [TestPlan::DependencyDelta::SourceDiff.new(path: "#{candidate.name}.rb", diff: "x" * (24 * 1024))]
    end

    result = generator(changes: changes, retriever: retriever).generate
    entries = result.dig(:manifest, "dependencies")

    expect(entries.first.fetch("context_files")).to eq(1)
    expect(entries.last.fetch("context_files")).to eq(0)
    expect(result.fetch(:context).bytesize).to be <= described_class::CONTEXT_TOTAL_LIMIT
  end

  it "keeps the build output of a linked release out of the provider context" do
    gem_change = TestPlan::DependencyDelta::Change.new(
      ecosystem: "bundler", name: "playbook_ui", old_version: "17.0.0", new_version: "17.1.0",
      source: "rubygems", old_locator: "https://rubygems.org/",
      new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
    )
    npm_change = TestPlan::DependencyDelta::Change.new(
      ecosystem: "yarn", name: "playbook-ui", old_version: "17.0.0", new_version: "17.1.0",
      source: "npm", old_locator: "https://registry.npmjs.org/playbook-ui/-/playbook-ui-17.0.0.tgz",
      new_locator: "https://registry.npmjs.org/playbook-ui/-/playbook-ui-17.1.0.tgz",
      direct: true, lockfiles: ["yarn.lock"]
    )
    builder = TestPlan::DependencyDelta::SourceDiffBuilder.new
    source_diff = lambda do |path|
      TestPlan::DependencyDelta::SourceDiff.new(
        path: path,
        diff: "--- a/#{path}\n+++ b/#{path}\n#{"x" * 512}\n",
        priority: builder.send(:priority, path)
      )
    end
    retriever = double("retriever")
    allow(retriever).to receive(:retrieve) do |candidate|
      if candidate.ecosystem == "bundler"
        [source_diff.call("app/pb_kits/playbook/pb_card/_card.tsx")]
      else
        [
          source_diff.call("dist/card.js"),
          source_diff.call("dist/ai/card.schema.json"),
          source_diff.call("package.json"),
        ]
      end
    end

    result = generator(changes: [gem_change, npm_change], retriever: retriever).generate
    entries = result.dig(:manifest, "dependencies").each_with_object({}) do |entry, index|
      index[entry.fetch("name")] = entry
    end

    # The bundles are dropped; package.json is not build output and still goes through.
    npm_entry = entries.fetch("playbook-ui")
    expect(npm_entry).to include(
      "status" => "retrieved",
      "context_files" => 1,
      "excluded_generated" => ["dist/ai/card.schema.json", "dist/card.js"]
    )
    expect(npm_entry.fetch("warnings").join).to include("generated build files")
    expect(result.fetch(:context)).to include("package.json")
    expect(result.fetch(:context)).not_to include("dist/card.js")

    # The source half is unaffected, and the artifact still holds everything.
    expect(entries.fetch("playbook_ui").fetch("context_files")).to eq(1)
    expect(result.fetch(:full)).to include("dist/card.js")
  end

  it "still sends build output for a dependency that has no linked source half" do
    builder = TestPlan::DependencyDelta::SourceDiffBuilder.new
    diffs = [
      TestPlan::DependencyDelta::SourceDiff.new(path: "dist/thing.js", diff: "x" * 2048,
                     priority: builder.send(:priority, "dist/thing.js")),
    ]

    result = generator(changes: [change], retriever: double("r", retrieve: diffs)).generate

    expect(result.dig(:manifest, "dependencies", 0, "context_files")).to eq(1)
  end
end
