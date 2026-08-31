require_relative "../../spec_helper"
require "test_plan/dependency_delta"

require "tempfile"

RSpec.describe TestPlan::DependencyDelta::Command do
  # Names, versions and paths come from lockfiles the pull request can edit, and the
  # summary is rendered as Markdown in the Actions UI.
  def summary_for(manifest)
    Tempfile.create("summary") do |file|
      ENV["GITHUB_STEP_SUMMARY"] = file.path
      described_class.new.send(:write_summary, manifest)
      File.read(file.path)
    ensure
      ENV.delete("GITHUB_STEP_SUMMARY")
    end
  end

  it "escapes dependency data before writing it into the job summary" do
    summary = summary_for(
      "dependencies" => [
        {
          "name" => "@evil/x <img src=q onerror=alert(1)>",
          "old_version" => "1.0.0",
          "new_version" => "2.0.0",
          "status" => "retrieved",
          "warnings" => ["Ping @someone at https://example.test/phish"],
          "omitted_from_context" => ["lib/[click](https://example.test).rb"],
        },
      ],
      "lockfile_warnings" => [{ "lockfile" => "a/Gemfile.lock", "warning" => "@here broke" }]
    )

    expect(summary).not_to include("<img", "@evil", "@someone", "@here")
    expect(summary).not_to include("https://example.test")
    expect(summary).to include("&lt;img", "&#64;evil", "https&#58;//example.test")
    expect(summary).to include("\\[click\\]")
  end

  it "leaves ordinary dependency data readable" do
    summary = summary_for(
      "dependencies" => [
        {
          "name" => "playbook_ui", "old_version" => "17.0.0", "new_version" => "17.1.0",
          "status" => "retrieved", "warnings" => [], "omitted_from_context" => []
        },
      ],
      "lockfile_warnings" => []
    )

    expect(summary).to include("- playbook_ui: 17.0.0 -> 17.1.0 (retrieved)")
  end
end
