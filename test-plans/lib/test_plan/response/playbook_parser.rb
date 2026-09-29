# frozen_string_literal: true
require "json"

require_relative "validation"
require_relative "../playbook/kit_facts"

module TestPlan
  module Response
    # Organizes a Playbook raise by changed kit rather than feature area.
    class PlaybookParser
      include Validation

      DEFAULT_KIT_CODE = "KIT"
      KIT_CODE_PATTERN = /\A[A-Z][A-Z0-9]{1,5}\z/

      attr_reader :kits, :other_dependencies, :regression_tests, :application_checks, :discarded

      def self.parse_file(path)
        new(File.read(path, encoding: Encoding::UTF_8))
      end

      def initialize(json_string)
        @discarded = []
        @payload = JSON.parse(extract_json(json_string))
        validate_root!
        @kits = build_kits
        @other_dependencies = build_other_dependencies
        @regression_tests = check_list(@payload["regression_tests"] || [], "regression test")
        @application_checks = check_list(@payload["application_checks"] || [], "application check")
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
          # The join key into the facts the action computed: an identifier the provider
          # copies is checkable in a way a number it reports is not.
          "slug" => normalize_text(entry["slug"]).downcase,
          "what_changed" => normalize_text(entry["what_changed"]),
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
          "system" => system(entry["system"]),
          "steps" => steps,
        }
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

      # Empty rather than guessed, so the plan does not label a React page as Rails.
      def system(value)
        candidate = normalize_text(value).downcase
        Playbook::KitFacts::SYSTEMS.include?(candidate) ? candidate : ""
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
