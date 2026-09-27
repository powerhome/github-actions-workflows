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
        raise 'Dependency test-plan JSON must include a "regression_tests" array' unless payload["regression_tests"].is_a?(Array)

        @dependencies = payload.fetch("dependencies").each_with_index.filter_map do |entry, index|
          dependency(entry, index + 1)
        end
        @regression_tests = checks(payload.fetch("regression_tests"), "regression test", dependency: true)
        @application_checks = checks(payload["application_checks"] || [], "application check")
      end

    private

      def dependency(entry, position)
        return discard("dependency #{position} was not an object") unless entry.is_a?(Hash)

        identity = %w[ecosystem name source from to].to_h do |field|
          [field, normalize_text(entry[field])]
        end
        return discard("dependency #{position} had no identity") if identity.values.any?(&:empty?)

        steps = entry.key?("steps") ? string_list(entry["steps"]) : []
        return discard("dependency #{position} had invalid steps") unless steps

        identity.merge("note" => normalize_text(entry["note"]), "steps" => steps)
      end

      def checks(entries, label, dependency: false)
        unless entries.is_a?(Array)
          discard("#{label} list was not an array")
          return []
        end

        entries.each_with_index.filter_map do |entry, index|
          next discard("#{label} #{index + 1} was not an object") unless entry.is_a?(Hash)

          title = normalize_text(entry["title"])
          steps = string_list(entry["steps"])
          next discard("#{label} #{index + 1} had no title or usable steps") if title.empty? || steps.nil? || steps.empty?

          result = { "title" => title, "page" => normalize_text(entry["page"]), "steps" => steps }
          if dependency
            name = normalize_text(entry["dependency"])
            next discard("#{label} #{index + 1} named no dependency") if name.empty?

            result["dependency"] = name
          end
          result
        end
      end
    end
  end
end
