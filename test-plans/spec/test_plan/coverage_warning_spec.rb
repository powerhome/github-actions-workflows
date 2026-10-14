# frozen_string_literal: true

require_relative "../spec_helper"
require "test_plan/coverage_warning"

RSpec.describe TestPlan::CoverageWarning do
  it "is empty when every changed file was read" do
    expect(described_class.for(files_reviewed: 5, changed_files: "5")).to eq("")
    expect(described_class.for(files_reviewed: 9, changed_files: "5")).to eq("")
  end

  it "is empty when the changed file count is unknown" do
    expect(described_class.for(files_reviewed: 1, changed_files: "")).to eq("")
    expect(described_class.for(files_reviewed: nil, changed_files: "0")).to eq("")
  end

  it "says how many files were read when that falls short" do
    expect(described_class.for(files_reviewed: 2, changed_files: "5")).to include("reading 2 of 5 changed files")
  end

  it "says so when the plan reports no count" do
    expect(described_class.for(files_reviewed: nil, changed_files: "5")).to include("did not report how many of the 5")
  end
end
