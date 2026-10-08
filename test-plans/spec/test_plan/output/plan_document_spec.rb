# frozen_string_literal: true

require_relative "../../spec_helper"

require "test_plan/output/dependency_formatter"
require "test_plan/response/dependency_parser"
require "test_plan/output/standard_formatter"
require "test_plan/response/standard_parser"
require "test_plan/output/playbook_formatter"
require "test_plan/response/playbook_parser"

require "json"

# Asserted against every plan shape at once, because the point of sharing these is that
# no shape can word them differently.
RSpec.describe TestPlan::Output::PlanDocument do
  STANDARD_PAYLOAD = {
    "permissions" => { "required" => "no", "roles" => [], "changes" => [], "subject_actions" => [] },
    "feature_areas" => [], "regression_tests" => []
  }.freeze

  SHAPES = {
    "standard" => lambda do |**options|
      payload = STANDARD_PAYLOAD.merge("feature_areas" => ["not an object", "also not an object"])
      TestPlan::Output::StandardFormatter.new(parsed: TestPlan::Response::StandardParser.new(JSON.generate(payload)),
                                              **options).render
    end,
    "playbook" => lambda do |**options|
      payload = { "kits" => ["not an object", "also not an object"] }
      TestPlan::Output::PlaybookFormatter.new(
        parsed: TestPlan::Response::PlaybookParser.new(JSON.generate(payload)), **options
      ).render
    end,
    "dependency" => lambda do |**options|
      payload = { "dependencies" => ["not an object", "also not an object"], "regression_tests" => [] }
      TestPlan::Output::DependencyFormatter.new(
        parsed: TestPlan::Response::DependencyParser.new(JSON.generate(payload)),
        manifest: { "dependencies" => [] }, **options
      ).render
    end,
  }.freeze

  def render(shape, profile_name: "Cobra Test Plan", pull_request_title: "Raise dependencies", warning: "")
    SHAPES.fetch(shape).call(
      pull_request_title:, profile_name:, generation_warning: warning
    )
  end

  SHAPES.each_key do |shape|
    context "the #{shape} plan" do
      it "opens with the profile name and the pull-request title" do
        expect(render(shape)).to start_with("## ✅ Cobra Test Plan: Raise dependencies\n")
      end

      it "falls back to a generic heading when the profile named nothing" do
        expect(render(shape, profile_name: "")).to start_with("## ✅ Test Plan: ")
      end

      it "omits the title suffix when there is no title" do
        expect(render(shape, pull_request_title: "")).to start_with("## ✅ Cobra Test Plan\n")
      end

      it "escapes the pull-request title, which its author writes" do
        output = render(shape, pull_request_title: "Ping @everyone <img>")

        expect(output).to include("&#64;everyone &lt;img&gt;")
        expect(output).not_to include("@everyone")
      end

      # Unusable parts are dropped rather than failing the run, so the plan has to say it
      # is not the whole of what was generated.
      it "says how many parts of the response it could not use" do
        expect(render(shape)).to include("> ⚠️ 2 parts of the generated response could not be used:")
      end

      it "carries the dependency-delta warning above everything else" do
        output = render(shape, warning: "Some external dependency evidence is incomplete")

        expect(output.lines[2]).to start_with("> ⚠️ Some external dependency evidence is incomplete")
      end

      it "collapses whitespace in the values it was handed" do
        expect(render(shape, pull_request_title: "Raise\n\n  dependencies"))
          .to start_with("## ✅ Cobra Test Plan: Raise dependencies\n")
      end
    end
  end
end
