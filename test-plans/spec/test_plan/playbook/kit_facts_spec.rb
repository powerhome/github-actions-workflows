require_relative "../../spec_helper"
require "test_plan/playbook/kit_facts"

require "json"
require "tempfile"

RSpec.describe TestPlan::Playbook::KitFacts do
  describe ".coverage" do
    it "calls a narrowly used kit complete and a widely used one representative" do
      expect(described_class.coverage(call_sites: described_class::COMPLETE_COVERAGE_MAX, searchable: true))
        .to eq(described_class::COMPLETE)
      expect(described_class.coverage(call_sites: described_class::COMPLETE_COVERAGE_MAX + 1, searchable: true))
        .to eq(described_class::REPRESENTATIVE)
    end

    it "distinguishes a kit nothing here uses from one it could not search for" do
      expect(described_class.coverage(call_sites: 0, searchable: true)).to eq(described_class::UNUSED)
      expect(described_class.coverage(call_sites: 0, searchable: false)).to eq(described_class::UNKNOWN)
    end

    # An unfinished search must never be published as exhaustive coverage.
    it "never reads as complete when the search could not finish" do
      expect(described_class.coverage(call_sites: 1, searchable: false)).not_to eq(described_class::COMPLETE)
    end
  end

  describe ".sentence" do
    it "gives each coverage its own claim" do
      expect(described_class.sentence(described_class::COMPLETE)).to eq(described_class::COMPLETE_SENTENCE)
      expect(described_class.sentence(described_class::UNUSED)).to eq(described_class::UNUSED_SENTENCE)
    end

    # "Testing every use is not practical" is a claim about how widely the kit is used, and
    # a search that did not finish supports no such claim.
    it "says the search failed rather than claiming a representative sample" do
      sentence = described_class.sentence(described_class::UNKNOWN)

      expect(sentence).to eq(described_class::UNKNOWN_SENTENCE)
      expect(sentence).not_to eq(described_class::REPRESENTATIVE_SENTENCE)
      expect(sentence).to include("could not be completed")
    end

    # A corrupt facts file should under-claim, not promise coverage.
    it "falls back to a representative sample for a value it does not know" do
      expect(described_class.sentence("something else")).to eq(described_class::REPRESENTATIVE_SENTENCE)
    end
  end

  it "labels the systems in a fixed order" do
    expect(described_class.systems_label(%w[react rails])).to eq("Rails and React")
    expect(described_class.systems_label(["react"])).to eq("React")
    expect(described_class.systems_label([])).to eq("")
  end

  describe "the round trip between the two steps" do
    let(:entries) do
      [{
        slug: "body", name: "Body", coverage: described_class::REPRESENTATIVE,
        call_sites: 1106, systems_changed: %w[rails react], systems_in_use: ["rails"],
      }]
    end

    it "survives being written and read back" do
      Tempfile.create(["facts", ".json"]) do |file|
        file.write(JSON.generate(described_class.document(entries)))
        file.flush

        fact = described_class.load_file(file.path).for(slug: "body", name: "Body")
        expect(fact).to include(
          "coverage" => described_class::REPRESENTATIVE,
          "call_sites" => 1106,
          "systems_changed" => %w[rails react],
          "systems_in_use" => ["rails"]
        )
      end
    end

    it "finds a kit by its display name when the slug did not come back" do
      document = described_class.new(described_class.document(entries).fetch("kits"))

      expect(document.for(slug: "", name: "Body")).not_to be_nil
      expect(document.for(slug: "", name: "Multi Level Select")).to be_nil
    end
  end

  describe "when there are no facts to read" do
    it "yields nothing rather than raising for a missing file" do
      expect(described_class.load_file("/nonexistent/facts.json").for(slug: "body", name: "Body")).to be_nil
    end

    it "yields nothing rather than raising for a file that is not the schema" do
      Tempfile.create(["facts", ".json"]) do |file|
        file.write("not json at all")
        file.flush

        expect(described_class.load_file(file.path).for(slug: "body", name: "Body")).to be_nil
      end
    end
  end
end
