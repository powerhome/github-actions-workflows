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
  def summary_for(manifest, kit_facts = { "kits" => {} })
    Tempfile.create("summary") do |file|
      ENV["GITHUB_STEP_SUMMARY"] = file.path
      described_class.new.send(:write_summary, manifest, kit_facts)
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

  # The counts left the evidence file so the provider has nothing to copy, which makes the
  # summary the place a person reads them.
  it "reports each changed kit's call sites in the job summary" do
    summary = summary_for(
      { "dependencies" => [], "lockfile_warnings" => [] },
      "kits" => {
        "dropdown" => { "name" => "Dropdown", "coverage" => "representative", "call_sites" => 23 },
        "dialog" => { "name" => "Dialog", "coverage" => "unused", "call_sites" => 0 },
      }
    )

    expect(summary).to include("- Playbook kits changed: 2")
    expect(summary).to include("Dropdown: 23 call sites (representative)")
    expect(summary).to include("Dialog: 0 call sites (unused)")
  end

  # First point in the run that can say the plan should be shaped by kit.
  it "reports whether the raise changed Playbook kits" do
    [[%w[dropdown file_upload], "true"], [[], "false"]].each do |kits, expected|
      Tempfile.create("output") do |file|
        ENV["GITHUB_OUTPUT"] = file.path
        described_class.new.send(:write_outputs, 4, 0, "", kits)
        expect(File.read(file.path)).to include("playbook_kits_changed=#{expected}")
      ensure
        ENV.delete("GITHUB_OUTPUT")
      end
    end
  end

  describe "the warning the pull-request comment carries" do
    def warning_for(dependencies, lockfile_warnings: [])
      described_class.new.send(
        :warning_message,
        "dependencies" => dependencies, "lockfile_warnings" => lockfile_warnings
      )
    end

    def truncated(name)
      { "name" => name, "status" => "truncated", "degraded" => false }
    end

    it "names the dependencies and why, rather than saying something went wrong" do
      warning = warning_for(
        [
          { "name" => "playbook_ui", "status" => "retrieved", "degraded" => false },
          truncated("irb"),
          truncated("minitest"),
        ]
      )

      expect(warning).to include("irb, minitest (provider context budget exhausted)")
      expect(warning).not_to include("playbook_ui")
    end

    it "states each reason once, however many dependencies share it" do
      warning = warning_for(
        [
          truncated("irb"),
          truncated("minitest"),
          { "name" => "internal-gem", "status" => "unavailable", "degraded" => true },
          { "name" => "proxied-pkg", "status" => "retrieved", "degraded" => true },
        ],
        lockfile_warnings: [{ "lockfile" => "a/Gemfile.lock", "warning" => "unparseable" }]
      )

      expect(warning).to include(
        "irb, minitest (provider context budget exhausted)",
        "internal-gem (could not be retrieved)",
        "proxied-pkg (source refused, changelog only)",
        "1 lockfile could not be analyzed"
      )
    end

    it "stops naming dependencies once the sentence stops being readable" do
      warning = warning_for((1..7).map { |index| truncated("gem-#{index}") })

      expect(warning).to include("gem-1, gem-2, gem-3, gem-4 and 3 more")
      expect(warning).not_to include("gem-5")
    end

    # The formatter renders this as handed, and GITHUB_OUTPUT ends the value at a newline.
    it "escapes lockfile-derived names and keeps the whole message on one line" do
      warning = warning_for(
        [{ "name" => "@evil/pkg <img src=q>\nsecond line", "status" => "unavailable", "degraded" => true }]
      )

      expect(warning).not_to include("@evil", "<img")
      expect(warning).to include("&#64;evil", "&lt;img")
      expect(warning).not_to include("\n")
    end

    it "says nothing when every dependency came back whole" do
      expect(warning_for([{ "name" => "nokogiri", "status" => "retrieved", "degraded" => false }])).to eq("")
    end
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
    expect(logged).to include("budget exhausted")
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

  it "names the skipped dependencies in the job summary" do
    summary = summary_for(
      "dependencies" => [],
      "lockfile_warnings" => [],
      "out_of_scope" => [
        {
          "ecosystem" => "bundler", "name" => "minitest", "old_version" => "5.25.5",
          "new_version" => "6.0.6", "lockfiles" => ["components/pigment/Gemfile.lock"],
        },
      ]
    )

    expect(summary).to include("1 raised dependency reached no root lockfile")
    expect(summary).to include("minitest: 5.25.5 -> 6.0.6")
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
