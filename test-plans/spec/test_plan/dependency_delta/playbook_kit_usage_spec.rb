require_relative "../../spec_helper"
require "test_plan/dependency_delta"

require "fileutils"
require "open3"
require "stringio"
require "tmpdir"

RSpec.describe TestPlan::DependencyDelta::PlaybookKitUsage do
  # A real git repository, because the search runs through `git grep` and its POSIX ERE
  # dialect is the thing most likely to break: \s and (?:...) are unsupported there and
  # match nothing rather than erroring.
  def workspace(files)
    Dir.mktmpdir do |root|
      files.each do |path, content|
        full = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, content)
      end
      Open3.capture3("git", "init", "--initial-branch", "main", ".", chdir: root)
      Open3.capture3("git", "add", "-A", chdir: root)
      yield root
    end
  end

  def playbook_change(name: "playbook_ui", ecosystem: "bundler")
    TestPlan::DependencyDelta::Change.new(
      ecosystem: ecosystem, name: name, old_version: "17.0.0", new_version: "17.1.0",
      source: "rubygems", old_locator: "https://rubygems.org/",
      new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
    )
  end

  def diff(path, priority: TestPlan::DependencyDelta::SourceDiffBuilder::PRIORITY_RUNTIME)
    TestPlan::DependencyDelta::SourceDiff.new(path: path, diff: "x", priority: priority)
  end

  let(:app) do
    {
      "components/directory/app/views/directory/index.html.erb" =>
        %(<%= pb_rails("multi_level_select", props: { id: "x" }) %>\n),
      "components/hr/app/views/hr/new_hire/_form.html.erb" =>
        %(<%= pb_rails( 'phone_number_input' ) %>\n),
      "components/hr/app/views/hr/new_hire/_sub.html.erb" =>
        %(<%= pb_rails("table/table_row") %>\n),
      "components/ui/app/javascript/Widget.tsx" =>
        %(import { MultiLevelSelect } from "playbook-ui"\nexport default () => <MultiLevelSelect />\n),
      "components/other/app/views/other/unrelated.html.erb" =>
        %(<%= pb_rails("body") %>\n),
    }
  end

  # The kit's stylesheet moves both sides of it, so both searches run.
  it "finds Rails and React usage of a changed kit" do
    workspace(app) do |root|
      usage = described_class.new(workspace: root)
      usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_multi_level_select/_x.scss")])

      report = usage.report
      expect(report).to include("## Multi Level Select (`multi_level_select`) — changed in Rails and React")
      expect(report).to include("components/directory/app/views/directory/index.html.erb")
      expect(report).to include("components/ui/app/javascript/Widget.tsx")
      expect(report).not_to include("unrelated.html.erb")
    end
  end

  it "matches single quotes and interior whitespace" do
    workspace(app) do |root|
      usage = described_class.new(workspace: root)
      usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_phone_number_input/_x.rb")])

      expect(usage.report).to include("components/hr/app/views/hr/new_hire/_form.html.erb")
    end
  end

  it "matches a kit used through a sub-template path" do
    workspace(app) do |root|
      usage = described_class.new(workspace: root)
      usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_table/_table.rb")])

      expect(usage.report).to include("components/hr/app/views/hr/new_hire/_sub.html.erb")
    end
  end

  describe "which side of a kit changed" do
    it "searches only the Rails side when only the Rails side moved" do
      workspace(app) do |root|
        usage = described_class.new(workspace: root)
        usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_multi_level_select/_x.html.erb")])

        report = usage.report
        expect(report).to include("— changed in Rails")
        expect(report).to include("**Rails call sites**")
        expect(report).not_to include("**React call sites**")
        expect(report).not_to include("Widget.tsx")
      end
    end

    it "searches only the React side when only the React side moved" do
      workspace(app) do |root|
        usage = described_class.new(workspace: root)
        usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_multi_level_select/_x.tsx")])

        report = usage.report
        expect(report).to include("— changed in React")
        expect(report).to include("Widget.tsx")
        expect(report).not_to include("**Rails call sites**")
      end
    end

    # The changed side is what a tester has to reopen, so a side nobody here renders has
    # to be said rather than left as an empty list.
    it "says so when a changed side is not rendered in this repository" do
      workspace(app) do |root|
        usage = described_class.new(workspace: root)
        usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_table/_table.scss")])

        report = usage.report
        expect(report).to include("— changed in Rails and React")
        expect(report).to include("changed the React side of this kit, but nothing in this repository renders it")
      end
    end
  end

  # Playbook ships a kit's docs and tests inside the kit directory, so without this a
  # release that only refreshed the docs site reported the kit as changed.
  describe "documentation and tests are not the kit changing" do
    it "does not register a kit whose only change is a doc example" do
      workspace(app) do |root|
        usage = described_class.new(workspace: root)
        usage.observe(playbook_change, [
          diff("app/pb_kits/playbook/pb_icon/docs/_icon_class.md",
               priority: TestPlan::DependencyDelta::SourceDiffBuilder::PRIORITY_DOC),
          diff("app/pb_kits/playbook/pb_icon/icon.test.js",
               priority: TestPlan::DependencyDelta::SourceDiffBuilder::PRIORITY_TEST),
        ])

        expect(usage.kits).to be_empty
        expect(usage.report).to be_nil
      end
    end

    it "still registers a kit that changed source alongside its docs" do
      workspace(app) do |root|
        usage = described_class.new(workspace: root)
        usage.observe(playbook_change, [
          diff("app/pb_kits/playbook/pb_table/docs/_table_docs.md",
               priority: TestPlan::DependencyDelta::SourceDiffBuilder::PRIORITY_DOC),
          diff("app/pb_kits/playbook/pb_table/_table.rb"),
        ])

        expect(usage.kits).to eq(["table"])
      end
    end
  end

  describe "coverage" do
    def card_workspace(component_count:, per_component:)
      (1..component_count).flat_map do |component|
        (1..per_component).map do |index|
          ["components/c#{component}/app/views/page_#{index}.html.erb", %(<%= pb_rails("card") %>\n)]
        end
      end.to_h
    end

    it "calls a widely used kit a representative sample and prints no count" do
      workspace(card_workspace(component_count: 10, per_component: 3)) do |root|
        usage = described_class.new(workspace: root)
        usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_card/_card.rb")])

        report = usage.report
        expect(report).to include("Testing every use is not practical")
        # Nothing for the provider to copy back as a count it cannot be checked on.
        expect(report).not_to match(/\b30 files\b/)
        expect(report.scan(/^- components/).length).to eq(described_class::SAMPLE_SIZE)
      end
    end

    # The bug stakeholders caught: every Icon example came from one component.
    it "spreads the sample across components rather than taking the first alphabetically" do
      files = card_workspace(component_count: 1, per_component: 20)
        .transform_keys { |path| path.sub("components/c1", "components/accounting") }
        .merge(card_workspace(component_count: 9, per_component: 1))

      workspace(files) do |root|
        usage = described_class.new(workspace: root)
        usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_card/_card.rb")])

        listed = usage.report.scan(/^- (\S+)/).flatten
        components = listed.map { |path| TestPlan::DependencyDelta::CallSiteSample.component(path) }
        expect(components.uniq.length).to eq(described_class::SAMPLE_SIZE)
      end
    end

    it "says every use is listed for a narrowly used kit" do
      workspace(card_workspace(component_count: 3, per_component: 1)) do |root|
        usage = described_class.new(workspace: root)
        usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_card/_card.rb")])

        report = usage.report
        expect(report).to include("Every use in this repository is listed below.")
        expect(report.scan(/^- components/).length).to eq(3)
      end
    end

    it "says so when a changed kit is not used here at all" do
      workspace(app) do |root|
        usage = described_class.new(workspace: root)
        usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_dialog/_dialog.rb")])

        expect(usage.report).to include("no use of it was found in this repository")
      end
    end
  end

  it "ignores dependencies that are not Playbook" do
    workspace(app) do |root|
      usage = described_class.new(workspace: root)
      usage.observe(
        playbook_change(name: "rack"),
        [diff("app/pb_kits/playbook/pb_multi_level_select/_x.tsx")]
      )

      expect(usage.report).to be_nil
    end
  end

  it "observes the npm half of the release as well" do
    workspace(app) do |root|
      usage = described_class.new(workspace: root)
      usage.observe(
        playbook_change(name: "playbook-ui", ecosystem: "yarn"),
        [diff("app/pb_kits/playbook/pb_multi_level_select/_x.tsx")]
      )

      expect(usage.report).to include("Multi Level Select")
    end
  end

  # "No usage found" is the one conclusion this file exists to support -- it tells a
  # tester there is nothing to open for a changed kit. Reaching it because the search
  # never ran is worse than producing no report at all.
  describe "when the search cannot run" do
    def annotations
      original = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end

    it "says the search failed rather than reporting no usage" do
      Dir.mktmpdir do |root|
        # Not a git repository, so git grep exits 128 rather than 0 or 1.
        usage = described_class.new(workspace: root)
        report = nil

        logged = annotations do
          usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_card/_card.rb")])
          report = usage.report
        end

        expect(report).to include("Card (`card`) — changed in Rails · search failed")
        expect(report).not_to include("No usage found")
        expect(logged).to include("::warning::Playbook kit usage search failed:", "exited 128")
      end
    end

    it "says so when git itself cannot be run" do
      workspace(app) do |root|
        # Stubbed inside the block: the fixture repository is built with git too.
        allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT, "git")
        usage = described_class.new(workspace: root)
        report = nil

        logged = annotations do
          usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_card/_card.rb")])
          report = usage.report
        end

        expect(report).to include("search failed")
        expect(logged).to include("git grep could not be run: Errno::ENOENT")
      end
    end

    # A kit whose stylesheet moved is searched on both sides, so one side can come back
    # while the other fails.
    it "does not report the half of a kit's search that did run" do
      ok = ["components/ui/app/javascript/Widget.tsx\n", "", instance_double(Process::Status, exitstatus: 0)]
      failed = ["", "fatal: bad pattern\n", instance_double(Process::Status, exitstatus: 128)]

      workspace(app) do |root|
        allow(Open3).to receive(:capture3).and_return(ok, failed)
        usage = described_class.new(workspace: root)
        report = nil

        annotations do
          usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_card/_card.scss")])
          report = usage.report
        end

        # A partial list of paths is indistinguishable from a complete one.
        expect(report).to include("search failed")
        expect(report).not_to include("Widget.tsx")
      end
    end
  end

  it "does nothing without a workspace" do
    usage = described_class.disabled
    usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_card/_card.rb")])

    expect(usage.report).to be_nil
  end
end
