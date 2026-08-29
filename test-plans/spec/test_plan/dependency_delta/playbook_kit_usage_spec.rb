require_relative "../../spec_helper"
require "test_plan/dependency_delta"

require "fileutils"
require "open3"
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

  it "does nothing without a workspace" do
    usage = described_class.disabled
    usage.observe(playbook_change, [diff("app/pb_kits/playbook/pb_card/_card.rb")])

    expect(usage.report).to be_nil
  end
end
