require_relative "../../spec_helper"
require "test_plan/dependency_delta"

RSpec.describe TestPlan::DependencyDelta::CallSiteSample do
  def paths_across(components, per_component)
    components.flat_map do |component|
      Array.new(per_component) { |index| "#{component}/app/views/page_#{index}.html.erb" }
    end
  end

  # The Icon bug, exactly: a kit used heavily in one component and lightly elsewhere.
  it "spreads a sample that lexicographic order would confine to one component" do
    clustered = paths_across(["components/accounting"], 40)
    elsewhere = paths_across(
      (1..9).map { |index| "components/zone#{index}" }, 1
    )

    sampled = described_class.spread((clustered + elsewhere).sort).first(8)

    expect(sampled.map { |path| described_class.component(path) }.uniq.length).to eq(8)
  end

  # The invariant rather than the fixture, so no future ordering change can pass this by
  # accident.
  it "uses as many distinct components as the sample size allows" do
    [[3, 20], [12, 2], [1, 30]].each do |component_count, per_component|
      paths = paths_across((1..component_count).map { |i| "components/c#{i}" }, per_component)

      sampled = described_class.spread(paths.sort).first(8)
      expect(sampled.map { |path| described_class.component(path) }.uniq.length)
        .to eq([8, component_count].min)
    end
  end

  # Kills a "one path per component, then stop" fix, which would return two paths here.
  it "keeps filling the sample when components run out" do
    paths = paths_across(["components/a", "components/b"], 10)

    expect(described_class.spread(paths).first(8).length).to eq(8)
  end

  # A dropped path loses a call site silently; a duplicated one publishes the same page
  # twice.
  it "returns a permutation of what it was given" do
    paths = paths_across(["components/a", "components/b", "app/javascript"], 4)

    expect(described_class.spread(paths).sort).to eq(paths.sort)
  end

  it "groups by component, and by top-level directory outside components/" do
    expect(described_class.component("components/sales/app/views/x.erb")).to eq("components/sales")
    expect(described_class.component("app/javascript/components/foo/X.tsx")).to eq("app")
    expect(described_class.component("Gemfile.lock")).to eq("Gemfile.lock")
  end

  it "has nothing to spread when given nothing" do
    expect(described_class.spread([])).to eq([])
  end
end
