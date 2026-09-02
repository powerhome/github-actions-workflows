require "json"

module TestPlan
  module Playbook
    # What the action worked out about each changed kit, carried from the step that built
    # the delta to the step that renders the comment.
    #
    # The two ends run in different steps, so this file owns the schema and the wording for
    # both of them: the evidence the provider reads and the comment a tester reads describe
    # the same coverage in the same words, and neither can drift from the other.
    class KitFacts
      VERSION = 1
      COMPLETE_COVERAGE_MAX = 4
      SYSTEMS = %w[rails react].freeze
      SYSTEM_LABELS = { "rails" => "Rails", "react" => "React" }.freeze

      COMPLETE = "complete"
      REPRESENTATIVE = "representative"
      UNUSED = "unused"
      UNKNOWN = "unknown"

      COMPLETE_SENTENCE = "Every use in this repository is listed below."
      REPRESENTATIVE_SENTENCE = "Testing every use is not practical; the pages below are a " \
        "representative sample."
      UNUSED_SENTENCE = "This upgrade changed this kit, but no use of it was found in this " \
        "repository."

      # A count this action could not complete never reads as exhaustive: an unfinished
      # search and an empty one are opposite claims.
      def self.coverage(call_sites:, searchable:)
        return UNKNOWN unless searchable
        return UNUSED if call_sites.zero?

        call_sites <= COMPLETE_COVERAGE_MAX ? COMPLETE : REPRESENTATIVE
      end

      def self.sentence(coverage)
        case coverage
        when COMPLETE then COMPLETE_SENTENCE
        when UNUSED then UNUSED_SENTENCE
        else REPRESENTATIVE_SENTENCE
        end
      end

      def self.systems_label(systems)
        named = SYSTEMS.select { |system| systems.include?(system) }.map { |s| SYSTEM_LABELS.fetch(s) }
        return "" if named.empty?

        named.join(" and ")
      end

      def self.document(entries)
        {
          "version" => VERSION,
          "kits" => entries.each_with_object({}) do |entry, kits|
            kits[entry.fetch(:slug)] = {
              "name" => entry.fetch(:name),
              "coverage" => entry.fetch(:coverage),
              "call_sites" => entry.fetch(:call_sites),
              "systems_changed" => entry.fetch(:systems_changed),
              "systems_in_use" => entry.fetch(:systems_in_use),
            }
          end,
        }
      end

      def self.none
        new({})
      end

      # Never raises. A plan rendered without facts reads as a representative sample
      # throughout, which under-claims; refusing to render would throw away a provider
      # result that has already been paid for.
      def self.load_file(path)
        payload = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
        return none unless payload.is_a?(Hash) && payload["kits"].is_a?(Hash)

        new(payload.fetch("kits"))
      rescue Errno::ENOENT, JSON::ParserError
        none
      end

      def initialize(kits)
        @kits = kits
      end

      # Joined on the slug the provider copies from the evidence heading, falling back to
      # the kit's display name. An identifier it can copy is checkable in a way a number it
      # reports is not.
      def for(slug:, name:)
        @kits[normalize(slug)] || @kits[normalize(name)]
      end

    private

      def normalize(value)
        value.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
      end
    end
  end
end
