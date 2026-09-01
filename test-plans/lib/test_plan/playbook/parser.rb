require "json"

require_relative "../agent_payload"

module TestPlan
  module Playbook
    # A Playbook raise is a pull request whose every file is a lockfile, so its plan is
    # organised by the kits the upgrade changed rather than by feature area, and every
    # case in it is a regression test. Nothing here maps onto the standard schema, so it
    # is parsed separately rather than bent into one shape that serves neither.
    class Parser
      include AgentPayload

      DEFAULT_KIT_CODE = "KIT"
      KIT_CODE_PATTERN = /\A[A-Z][A-Z0-9]{1,5}\z/

      attr_reader :kits, :cross_cutting, :other_dependencies, :discarded

      def self.parse_file(path)
        new(File.read(path, encoding: Encoding::UTF_8))
      end

      def initialize(json_string)
        @discarded = []
        @payload = JSON.parse(extract_json(json_string))
        validate_root!
        @kits = build_kits
        @cross_cutting = build_cross_cutting
        @other_dependencies = build_other_dependencies
      end

    private

      def validate_root!
        raise "Test-plan JSON root must be a JSON object" unless @payload.is_a?(Hash)
        raise 'Playbook test-plan JSON must include a "kits" array' unless @payload["kits"].is_a?(Array)
      end

      def build_kits
        @payload.fetch("kits").each_with_index.filter_map do |entry, index|
          build_kit(entry, index + 1)
        end
      end

      def build_kit(entry, position)
        return discard("kit #{position} was not an object") unless entry.is_a?(Hash)

        name = normalize_text(entry["name"])
        return discard("kit #{position} had no name") if name.empty?

        cases = Array(entry["cases"]).each_with_index.filter_map do |item, index|
          build_case(item, "#{name} #{index + 1}")
        end
        return discard("kit #{name} had no usable cases") if cases.empty?

        {
          "name" => name,
          "what_changed" => normalize_text(entry["what_changed"]),
          # Reported by the provider, which copies it from the evidence file rather than
          # counting. The coverage tier is derived from it downstream, so the provider
          # cannot call a sample exhaustive.
          "use_count" => use_count(entry["use_count"], cases.length),
          "code" => kit_code(entry["code"], name),
          "cases" => cases,
        }
      end

      def build_case(entry, position)
        return discard("case #{position} was not an object") unless entry.is_a?(Hash)

        title = normalize_text(entry["title"])
        steps = string_list(entry["steps"])
        return discard("case #{position} had no title") if title.empty?
        return discard("case #{title} had no steps array of strings") if steps.nil?
        return discard("case #{title} had no steps") if steps.empty?

        {
          "title" => title,
          "page" => normalize_text(entry["page"]),
          "source" => normalize_text(entry["source"]),
          "access" => normalize_text(entry["access"]),
          "steps" => steps,
        }
      end

      def build_cross_cutting
        Array(@payload["cross_cutting"]).each_with_index.filter_map do |entry, index|
          next discard("cross-cutting entry #{index + 1} was not an object") unless entry.is_a?(Hash)

          area = normalize_text(entry["area"])
          next discard("cross-cutting entry #{index + 1} had no area") if area.empty?

          {
            "area" => area,
            "paths" => unique_strings(Array(entry["paths"])),
            "risk" => normalize_text(entry["risk"]),
            "steps" => unique_strings(Array(entry["steps"])),
          }
        end
      end

      def build_other_dependencies
        Array(@payload["other_dependencies"]).each_with_index.filter_map do |entry, index|
          next discard("other dependency #{index + 1} was not an object") unless entry.is_a?(Hash)

          name = normalize_text(entry["name"])
          next discard("other dependency #{index + 1} had no name") if name.empty?

          {
            "name" => name,
            "from" => normalize_text(entry["from"]),
            "to" => normalize_text(entry["to"]),
            "note" => normalize_text(entry["note"]),
            "steps" => unique_strings(Array(entry["steps"])),
          }
        end
      end

      # Never below the number of cases written: a count that undercounts its own case
      # list would render as an exhaustive tier while listing more pages than it claims
      # exist.
      def use_count(value, case_count)
        count = value.is_a?(Integer) && value.positive? ? value : 0
        [count, case_count].max
      end

      def kit_code(value, name)
        code = normalize_text(value).upcase
        return code if KIT_CODE_PATTERN.match?(code)

        derived = name.upcase.gsub(/[^A-Z0-9]/, "")[0, 3].to_s
        KIT_CODE_PATTERN.match?(derived) ? derived : DEFAULT_KIT_CODE
      end
    end
  end
end
