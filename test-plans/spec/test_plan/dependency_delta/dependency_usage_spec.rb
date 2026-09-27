require_relative "../../spec_helper"
require "test_plan/dependency_delta/dependency_usage"
require "test_plan/dependency_delta/change"

require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe TestPlan::DependencyDelta::DependencyUsage do
  def change(name)
    TestPlan::DependencyDelta::Change.new(name: name)
  end

  it "finds name variants in application files and excludes specs" do
    Dir.mktmpdir do |directory|
      files = {
        "components/pulse-ui/app/menu.rb" => "require 'example_widget'\n",
        "components/connect-web-ui/app/menu.tsx" => "import 'example-widget'\n",
        "components/pulse-ui/spec/menu_spec.rb" => "require 'example_widget'\n",
      }
      files.each do |path, content|
        absolute = File.join(directory, path)
        FileUtils.mkdir_p(File.dirname(absolute))
        File.write(absolute, content)
      end
      Open3.capture3("git", "init", "--quiet", directory)
      Open3.capture3("git", "add", "-A", chdir: directory)

      report = described_class.new(workspace: directory).report([change("example-widget")])

      expect(report).to include("## example-widget")
      expect(report).to include("components/pulse-ui/app/menu.rb", "components/connect-web-ui/app/menu.tsx")
      expect(report).not_to include("components/pulse-ui/spec/menu_spec.rb")
    end
  end

  it "reports an unsuccessful search without claiming there are no uses" do
    report = described_class.new(workspace: "/missing/workspace").report([change("widget")])

    expect(report).to include("Usage search failed")
    expect(report).not_to include("No application source file matched")
  end
end
