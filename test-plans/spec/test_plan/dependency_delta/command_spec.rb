require_relative "../../spec_helper"
require "test_plan/dependency_delta"

require "stringio"
require "tempfile"

RSpec.describe TestPlan::DependencyDelta::Command do
  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

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

  it "echoes the manifest into a collapsed log group so an ephemeral runner leaves a record" do
    manifest = {
      "version" => 1,
      "dependencies" => [
        { "name" => "playbook_ui", "status" => "unavailable", "warnings" => ["registry said no"] },
      ],
      "warning_count" => 1,
    }

    logged = capture_stdout { described_class.new.send(:log_manifest, "/tmp/manifest.json", manifest) }

    expect(logged).to include(
      "::group::Dependency delta manifest (/tmp/manifest.json)",
      "registry said no",
      "::endgroup::"
    )
  end

  it "trims a long lockfile list in the log without touching the manifest" do
    lockfiles = Array.new(142) { |index| "components/component#{index}/Gemfile.lock" }
    manifest = {
      "dependencies" => [
        { "name" => "playbook_ui", "lockfiles" => lockfiles, "warnings" => ["budget exhausted"] },
      ],
    }

    logged = capture_stdout { described_class.new.send(:log_manifest, "/tmp/manifest.json", manifest) }

    expect(logged).to include("components/component0/Gemfile.lock")
    expect(logged).to include("...and 137 more (see the manifest artifact)")
    expect(logged).not_to include("components/component100/Gemfile.lock")
    # The warning is the reason to read this group at all, so it has to survive.
    expect(logged).to include("budget exhausted")
    # The manifest written to disk and uploaded keeps every lockfile.
    expect(manifest.dig("dependencies", 0, "lockfiles").length).to eq(142)
  end

  it "leaves a short lockfile list alone" do
    manifest = { "dependencies" => [{ "name" => "nokogiri", "lockfiles" => ["Gemfile.lock"] }] }

    logged = capture_stdout { described_class.new.send(:log_manifest, "/tmp/manifest.json", manifest) }

    expect(logged).to include("Gemfile.lock")
    expect(logged).not_to include("more (see the manifest artifact)")
  end

  # A workflow command is only recognised at the start of a line, so JSON's own newline
  # escaping is the guard.
  it "cannot be made to emit a workflow command from lockfile-derived text" do
    manifest = { "dependencies" => [{ "name" => "x\n::error::owned" }] }

    logged = capture_stdout { described_class.new.send(:log_manifest, "/tmp/manifest.json", manifest) }

    expect(logged).to include("::error::owned")
    expect(logged.lines.map(&:chomp).grep(/\A\s*::/))
      .to eq(["::group::Dependency delta manifest (/tmp/manifest.json)", "::endgroup::"])
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
