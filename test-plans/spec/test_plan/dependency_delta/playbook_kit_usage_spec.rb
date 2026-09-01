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

  def diff(path)
    TestPlan::DependencyDelta::SourceDiff.new(path: path, diff: "x", priority: 1)
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

  it "finds Rails and React usage of a changed kit" do
    workspace(app) do |root|
      usage = described_class.new(workspace: root)
      usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_multi_level_select/_x.tsx")])

      report = usage.report
      expect(report).to include("## Multi Level Select (`multi_level_select`) — 2 files")
      expect(report).to include("components/directory/app/views/directory/index.html.erb")
      expect(report).to include("components/ui/app/javascript/Widget.tsx")
      expect(report).not_to include("unrelated.html.erb")
    end
  end

  it "matches single quotes and interior whitespace" do
    workspace(app) do |root|
      usage = described_class.new(workspace: root)
      usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_phone_number_input/_x.rb")])

      expect(usage.report).to include("Phone Number Input (`phone_number_input`) — 1 file")
    end
  end

  it "matches a kit used through a sub-template path" do
    workspace(app) do |root|
      usage = described_class.new(workspace: root)
      usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_table/_table.rb")])

      expect(usage.report).to include("Table (`table`) — 1 file")
    end
  end

  it "takes the kit list from the changed paths, ignoring non-kit files" do
    workspace(app) do |root|
      usage = described_class.new(workspace: root)
      usage.observe(playbook_change, [
        diff("app/pb_kits/playbook/pb_multi_level_select/_x.tsx"),
        diff("lib/playbook/version.rb"),
        diff("dist/playbook.css"),
      ])

      expect(usage.report.scan(/^## /).length).to eq(1)
    end
  end

  it "reports a widely used kit as a count rather than a list" do
    files = (1..30).to_h do |n|
      ["components/wide/app/views/page_#{n}.html.erb", %(<%= pb_rails("card") %>\n)]
    end

    workspace(files) do |root|
      usage = described_class.new(workspace: root)
      usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_card/_card.rb")])

      report = usage.report
      expect(report).to include("Card (`card`) — 30 files", "Used too widely to list")
      expect(report).not_to include("page_1.html.erb")
    end
  end

  it "says so when a changed kit is not used here at all" do
    workspace(app) do |root|
      usage = described_class.new(workspace: root)
      usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_dialog/_dialog.rb")])

      expect(usage.report).to include("Dialog (`dialog`) — 0 files", "No usage found")
    end
  end

  it "lists the kits it observed, which is what marks the raise as a Playbook one" do
    workspace({}) do |root|
      usage = described_class.new(workspace: root)
      usage.observe(
        playbook_change,
        [diff("app/pb_kits/playbook/pb_dropdown/index.tsx"), diff("app/pb_kits/playbook/pb_body/_body.tsx")]
      )

      expect(usage.kits).to eq(%w[body dropdown])
    end
  end

  it "has no kits when nothing Playbook changed" do
    workspace({}) do |root|
      usage = described_class.new(workspace: root)
      usage.observe(
        TestPlan::DependencyDelta::Change.new(
          ecosystem: "bundler", name: "nokogiri", old_version: "1.0.0", new_version: "1.0.1",
          source: "rubygems", old_locator: "https://rubygems.org/",
          new_locator: "https://rubygems.org/", direct: true, lockfiles: ["Gemfile.lock"]
        ),
        [diff("lib/nokogiri.rb")]
      )

      expect(usage.kits).to be_empty
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

        expect(report).to include("Card (`card`) — search failed")
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

    it "does not report the half of a kit's search that did run" do
      ok = ["components/ui/app/javascript/Widget.tsx\n", "", instance_double(Process::Status, exitstatus: 0)]
      failed = ["", "fatal: bad pattern\n", instance_double(Process::Status, exitstatus: 128)]

      workspace(app) do |root|
        allow(Open3).to receive(:capture3).and_return(ok, failed)
        usage = described_class.new(workspace: root)
        report = nil

        annotations do
          usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_card/_card.rb")])
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
