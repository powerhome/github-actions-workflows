# frozen_string_literal: true

require_relative "../../spec_helper"
require "test_plan/dependency_delta/dependency_usage"
require "test_plan/dependency_delta/change"

require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe TestPlan::DependencyDelta::DependencyUsage do
  def change(name)
    TestPlan::DependencyDelta::Change.new(name:)
  end

  # git grep answers from the index, so the files only have to be added, not committed.
  def workspace(files)
    Dir.mktmpdir do |directory|
      files.each do |path, content|
        absolute = File.join(directory, path)
        FileUtils.mkdir_p(File.dirname(absolute))
        File.write(absolute, content, encoding: Encoding::UTF_8)
      end
      Open3.capture3("git", "init", "--quiet", directory)
      Open3.capture3("git", "add", "-A", chdir: directory)

      yield directory
    end
  end

  it "finds name variants in application files and excludes specs" do
    files = {
      "components/pulse-ui/app/menu.rb" => "require 'example_widget'\n",
      "components/connect-web-ui/app/menu.tsx" => "import 'example-widget'\n",
      "components/pulse-ui/spec/menu_spec.rb" => "require 'example_widget'\n",
    }

    workspace(files) do |directory|
      report = described_class.new(workspace: directory).report([change("example-widget")])

      expect(report).to include("## example-widget")
      expect(report).to include("components/pulse-ui/app/menu.rb", "components/connect-web-ui/app/menu.tsx")
      expect(report).not_to include("components/pulse-ui/spec/menu_spec.rb")
    end
  end

  # A committed bundle inlines its dependencies, matching every package name searched for.
  it "excludes build output and vendored code" do
    files = {
      "app/menu.rb" => "require 'widget'\n",
      "public/dist/bundle.js" => "widget\n",
      "components/pulse-ui/build/out.js" => "widget\n",
      "vendor/widget/index.js" => "widget\n",
      "node_modules/widget/index.js" => "widget\n",
      "docs/widget.md" => "widget\n",
    }

    workspace(files) do |directory|
      report = described_class.new(workspace: directory).report([change("widget")])

      expect(report).to include("- app/menu.rb")
      expect(report).not_to include("bundle.js", "out.js", "vendor/", "node_modules/", "docs/")
    end
  end

  # git grep exits 1 for "matched nothing", which licenses saying so where a failure does
  # not.
  it "says a package matched nothing when the search found nothing" do
    workspace("app/menu.rb" => "require 'something_else'\n") do |directory|
      report = described_class.new(workspace: directory).report([change("widget")])

      expect(report).to include("No application source file matched this package name")
      expect(report).not_to include("Usage search failed")
    end
  end

  it "reports an unsuccessful search without claiming there are no uses" do
    report = described_class.new(workspace: "/missing/workspace").report([change("widget")])

    expect(report).to include("Usage search failed")
    expect(report).not_to include("No application source file matched")
  end

  it "caps the files listed per package and says it capped them" do
    files = (1..12).to_h { |index| ["app/models/widget_#{index}.rb", "require 'widget'\n"] }

    workspace(files) do |directory|
      report = described_class.new(workspace: directory).report([change("widget")])

      expect(report.scan(/^- app\//).length).to eq(described_class::MAX_FILES_PER_PACKAGE)
      expect(report).to include("- ...additional matches omitted")
    end
  end

  # Lexicographically, the first eight matches are eight files in one component.
  it "spreads the sample across components rather than taking it off the front" do
    files = {}
    %w[accounting billing contact_center].each do |component|
      (1..4).each { |index| files["components/#{component}/app/widget_#{index}.rb"] = "require 'widget'\n" }
    end

    workspace(files) do |directory|
      report = described_class.new(workspace: directory).report([change("widget")])

      expect(report).to include("components/accounting/", "components/billing/", "components/contact_center/")
    end
  end

  it "says plainly when there was nothing to search for" do
    report = described_class.new(workspace: "/unused").report([])

    expect(report).to include("No in-scope dependency raises were found.")
    expect(report).not_to include("Usage search failed")
  end

  it "escapes package names and paths, which come from lockfiles the pull request can edit" do
    workspace("app/menu.rb" => "require '@evil/x'\n") do |directory|
      report = described_class.new(workspace: directory).report([change("@evil/x")])

      expect(report).to include("## &#64;evil/x")
      expect(report).not_to include("## @evil/x")
    end
  end
end
