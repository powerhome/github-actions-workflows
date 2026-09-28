require "json"

require_relative "../agent_payload"

module TestPlan
  module Dependency
    class Parser
      include AgentPayload

      attr_reader :dependencies, :regression_tests, :application_checks, :discarded

      def self.parse_file(path)
        new(File.read(path, encoding: Encoding::UTF_8))
      end

      def initialize(json_string)
        @discarded = []
        payload = JSON.parse(extract_json(json_string))
        raise "Dependency test-plan JSON root must be an object" unless payload.is_a?(Hash)
        raise 'Dependency test-plan JSON must include a "dependencies" array' unless payload["dependencies"].is_a?(Array)

        @dependencies = payload.fetch("dependencies").each_with_index.filter_map do |entry, index|
          dependency(entry, index + 1)
        end
        # Optional, like the application checks beside them: a response that traced no use
        # was told to send an empty array, and sending no array means the same. The plan
        # still has every version change the manifest recorded.
        @regression_tests = check_list(payload["regression_tests"] || [], "regression test", dependency: true)
        @application_checks = check_list(payload["application_checks"] || [], "application check")
      end

    private

      # What the formatter matches on, and only that. `source` is an internal enum no
      # reader of the plan sees, so requiring it back costs a response its note for
      # nothing.
      IDENTITY_FIELDS = %w[ecosystem name from to].freeze

      def dependency(entry, position)
        return discard("dependency #{position} was not an object") unless entry.is_a?(Hash)

        identity = IDENTITY_FIELDS.to_h { |field| [field, normalize_text(entry[field])] }
        return discard("dependency #{position} had no identity") if identity.values.any?(&:empty?)

        steps = entry.key?("steps") ? string_list(entry["steps"]) : []
        return discard("dependency #{position} had invalid steps") unless steps

        identity.merge("note" => normalize_text(entry["note"]), "steps" => steps)
      end
    end
  end
end
