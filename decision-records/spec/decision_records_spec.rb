# frozen_string_literal: true

require_relative "spec_helper"
require "decision_records"

require "fileutils"
require "tmpdir"

RSpec.describe DecisionRecords do
  around do |example|
    Dir.mktmpdir("decision-records") do |root|
      @root = root
      example.run
    end
  end

  def write(path, content)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def adr(status: '"accepted"', makers: "Jane Doe", title: "Use one queue per wait-time tier", extra: "")
    <<~MARKDOWN
      ---
      status: #{status}
      date: 2026-11-15
      decision-makers: #{makers}
      #{extra}---

      # #{title}

      ## Context and Problem Statement

      Why.

      ## Considered Options

      - One queue per tier

      ## Decision Outcome

      Chosen option: "One queue per tier", because it is simplest.

      ### Consequences

      - Good, because it is simple.
    MARKDOWN
  end

  def cir(number: "0001", supersedes: nil, date: "2026-11-15")
    <<~MARKDOWN
      # CIR-#{number}: Cap the logs volume by size

      ## Intent

      Stop the volume filling.

      ## Behavior

      - GIVEN a full volume
      - WHEN logs are written
      - THEN the oldest are removed

      ## Constraints

      - The volume cannot grow.

      ## Decisions

      - Rejected: a larger volume, because it only delays the problem.

      ## Date

      #{date}
      #{supersedes ? "\nSupersedes: CIR-#{supersedes}\n" : ''}
    MARKDOWN
  end

  def problems(**options)
    described_class.check(root: @root, **options).map(&:to_s)
  end

  describe "ADRs" do
    it "accepts well-formed records and their template and index" do
      write("docs/decisions/0001-use-tiers.md", adr)
      write("docs/decisions/0002-drop-tiers.md", adr(status: '"superseded by ADR-0001"'))
      write("docs/decisions/0003-maybe.md", adr(status: '"proposed"', makers: '""'))
      write("docs/decisions/adr-template.md", "anything")
      write("docs/decisions/README.md", "anything")

      expect(problems(adr_dirs: ["docs/decisions"])).to be_empty
    end

    it "reports a shared number with the next free number" do
      write("docs/decisions/0001-first.md", adr)
      write("docs/decisions/0001-second.md", adr)
      write("docs/decisions/0002-third.md", adr)

      expect(problems(adr_dirs: ["docs/decisions"])).to contain_exactly(
        a_string_including("docs/decisions/0001-second.md: number 0001 is shared by 0001-first.md, 0001-second.md; " \
                           "renumber the later record to 0003, the next number")
      )
    end

    it "leaves gaps alone without a base branch" do
      write("docs/decisions/0001-a.md", adr)
      write("docs/decisions/0004-b.md", adr)

      expect(problems(adr_dirs: ["docs/decisions"])).to be_empty
    end

    it "reports misnamed files" do
      write("docs/decisions/ADR-001-old.md", adr)
      write("docs/decisions/20260119-dated.md", adr)

      expect(problems(adr_dirs: ["docs/decisions"]).size).to eq(2)
      expect(problems(adr_dirs: ["docs/decisions"])).to all(include("NNNN-title-with-dashes.md"))
    end

    it "reports missing front matter" do
      write("docs/decisions/0001-bare.md", "# A decision\n\n- Status: Accepted\n")

      expect(problems(adr_dirs: ["docs/decisions"])).to eq(
        ["docs/decisions/0001-bare.md: missing YAML front matter between --- lines"]
      )
    end

    it "reports an unknown status, a missing supersession target and missing decision-makers" do
      write("docs/decisions/0001-a.md", adr(status: '"Accepted (2026-06-07)"'))
      write("docs/decisions/0002-b.md", adr(status: '"superseded by ADR-0009"'))
      write("docs/decisions/0003-c.md", adr(makers: '""'))

      found = problems(adr_dirs: ["docs/decisions"])
      expect(found).to include(a_string_including("0001-a.md: status \"Accepted (2026-06-07)\" must be one of"))
      expect(found).to include("docs/decisions/0002-b.md: superseded by ADR-0009, which does not exist")
      expect(found).to include("docs/decisions/0003-c.md: decision-makers are required once an ADR is accepted")
    end

    it "reports front matter keys MADR does not define" do
      write("docs/decisions/0001-a.md", adr(extra: "rfc: 0115\n"))

      expect(problems(adr_dirs: ["docs/decisions"])).to contain_exactly(a_string_including("unknown front matter rfc"))
    end

    it "reports a numbered title and missing sections" do
      write("docs/decisions/0001-a.md", adr(title: "1. Use tiers").sub("## Considered Options", "## Alternatives"))

      expect(problems(adr_dirs: ["docs/decisions"])).to contain_exactly(
        a_string_including("the title should state the decision without a number"),
        a_string_including("missing the ## Considered Options section")
      )
    end

    it "reports missing sections and a numbered title as warnings, not errors" do
      write("docs/decisions/0001-a.md", adr(title: "1. Use tiers").sub("## Considered Options", "## Alternatives"))

      found = described_class.check(root: @root, adr_dirs: ["docs/decisions"])
      expect(found).to all(be_warning)
      expect(found.map(&:to_s)).to include(a_string_including("warning: missing the ## Considered Options section"))
    end

    it "reports objective problems as errors" do
      write("docs/decisions/0001-a.md", adr(status: '"done"'))
      write("docs/decisions/0001-b.md", adr)

      found = described_class.check(root: @root, adr_dirs: ["docs/decisions"])
      expect(found).not_to be_empty
      expect(found.none?(&:warning?)).to be(true)
    end

    it "accepts section headings in sentence case" do
      write("docs/decisions/0001-a.md", adr.sub("Context and Problem Statement", "Context and problem statement"))

      expect(problems(adr_dirs: ["docs/decisions"])).to be_empty
    end

    it "reports a directory that does not exist" do
      expect(problems(adr_dirs: ["docs/missing"])).to eq(["docs/missing: directory does not exist"])
    end
  end

  describe "CIRs" do
    it "accepts well-formed records and their template" do
      write("docs/cir/0001-cap-logs.md", cir)
      write("docs/cir/0002-cap-logs-again.md", cir(number: "0002", supersedes: "0001"))
      write("docs/cir/cir-template.md", "anything")

      expect(problems(cir_dirs: ["docs/cir"])).to be_empty
    end

    it "reports a title that disagrees with the file name" do
      write("docs/cir/0001-cap-logs.md", cir(number: "0003"))

      expect(problems(cir_dirs: ["docs/cir"])).to eq(
        ["docs/cir/0001-cap-logs.md: title says CIR-0003 but the file is 0001"]
      )
    end

    it "reports missing sections, an undated record and a missing supersession target" do
      write("docs/cir/0001-cap-logs.md", cir(date: "soon", supersedes: "0009").sub("## Constraints", "## Limits"))

      expect(problems(cir_dirs: ["docs/cir"])).to contain_exactly(
        a_string_including("missing the ## Constraints section"),
        a_string_including("the Date section needs a date"),
        a_string_including("supersedes CIR-0009, which does not exist")
      )
    end

    it "reports shared numbers" do
      write("docs/cir/0001-one.md", cir(number: "0001"))
      write("docs/cir/0001-two.md", cir(number: "0001"))

      expect(problems(cir_dirs: ["docs/cir"])).to contain_exactly(a_string_including("number 0001 is shared"))
    end
  end

  describe "records added beyond the default branch" do
    def git(*args)
      system("git", "-C", @root, *args, out: File::NULL, err: File::NULL, exception: true)
    end

    # Commits what is written so far as the default branch, and returns its ref.
    def commit_base
      git("init", "-q")
      git("add", "-A")
      git("-c", "user.name=spec", "-c", "user.email=spec@example.com", "commit", "-q", "-m", "base")
      "HEAD"
    end

    before do
      write("docs/decisions/0001-a.md", adr)
      write("docs/decisions/0002-b.md", adr)
      write("docs/decisions/0005-after-a-gap.md", adr)
    end

    it "accepts numbers above the highest on the default branch, keeping old gaps" do
      base = commit_base
      write("docs/decisions/0006-new.md", adr)
      write("docs/decisions/0007-newer.md", adr)

      expect(problems(adr_dirs: ["docs/decisions"], base:)).to be_empty
    end

    it "accepts a new record that skips ahead" do
      base = commit_base
      write("docs/decisions/0009-ahead.md", adr)

      expect(problems(adr_dirs: ["docs/decisions"], base:)).to be_empty
    end

    it "reports a new record that fills an old gap" do
      base = commit_base
      write("docs/decisions/0003-in-the-gap.md", adr)

      expect(problems(adr_dirs: ["docs/decisions"], base:)).to eq(
        ["docs/decisions/0003-in-the-gap.md: a new record must be numbered higher than 0005, the highest on HEAD; " \
         "take 0006"]
      )
    end

    it "reports a race lost to the default branch only as a shared number" do
      base = commit_base
      write("docs/decisions/0005-lost-the-race.md", adr)

      expect(problems(adr_dirs: ["docs/decisions"], base:)).to contain_exactly(
        a_string_including("number 0005 is shared by 0005-after-a-gap.md, 0005-lost-the-race.md")
      )
    end

    it "counts pre-migration names on the default branch" do
      write("docs/cir/CIR-012-old.md", cir(number: "0012"))
      base = commit_base
      write("docs/cir/0013-new.md", cir(number: "0013"))

      found = problems(cir_dirs: ["docs/cir"], base:)
      expect(found).not_to include(a_string_including("a new record must be"))
    end
  end

  describe "the MkDocs nav" do
    before do
      write("docs/decisions/0001-a.md", adr)
      write("docs/decisions/0002-b.md", adr)
    end

    it "requires every record where the nav lists records one by one" do
      write("mkdocs.yml", "nav:\n  - Decisions:\n      - decisions/0001-a.md\n")

      expect(problems(adr_dirs: ["docs/decisions"], mkdocs: "mkdocs.yml")).to eq(
        ["docs/decisions/0002-b.md: missing from the mkdocs.yml nav"]
      )
    end

    it "leaves a nav that collects records by glob alone" do
      write("mkdocs.yml", "nav:\n  - Decisions:\n      - ... | flat | decisions/*.md\n")

      expect(problems(adr_dirs: ["docs/decisions"], mkdocs: "mkdocs.yml")).to be_empty
    end

    it "honours docs_dir" do
      write("site/decisions/0001-a.md", adr)
      write("site/decisions/0002-b.md", adr)
      write("mkdocs.yml", "docs_dir: site\nnav:\n  - decisions/0001-a.md\n")

      expect(problems(adr_dirs: ["site/decisions"], mkdocs: "mkdocs.yml")).to eq(
        ["site/decisions/0002-b.md: missing from the mkdocs.yml nav"]
      )
    end

    it "is skipped when the config does not exist" do
      expect(problems(adr_dirs: ["docs/decisions"], mkdocs: "mkdocs.yml")).to be_empty
    end
  end
end
