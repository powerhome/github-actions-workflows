require "json"

module TestPlan
  # Recovery and normalisation shared by every plan shape. The provider answers with JSON
  # somewhere inside prose, and nothing it returns can be trusted to be the type the
  # schema says. Includers set @discarded before parsing.
  module AgentPayload
  private

    def extract_json(raw)
      stripped = strip_code_fences(raw)
      return stripped if valid_json_object?(stripped)

      first_brace = raw.index("{")
      last_brace = raw.rindex("}")
      if first_brace && last_brace && last_brace > first_brace
        candidate = raw[first_brace..last_brace]
        return candidate if valid_json_object?(candidate)
      end

      stripped
    end

    def strip_code_fences(raw)
      stripped = raw.strip
      stripped = stripped.sub(/\A```\w*\s*\n?/, "").sub(/\n?```\s*\z/, "") if stripped.start_with?("```")
      stripped
    end

    def valid_json_object?(string)
      JSON.parse(string).is_a?(Hash)
    rescue JSON::ParserError
      false
    end

    # Steps are the plan's instructions, and the schema says they are strings. Coercing
    # anything else produces a published step reading {"x"=>1}. Returns nil when the value
    # is not an array of strings, so the caller can record why it went.
    def string_list(values)
      return nil unless values.is_a?(Array)
      return nil unless values.all? { |value| value.is_a?(String) }

      unique_strings(values)
    end

    # Supporting collections drop what they cannot use rather than discarding the entry
    # around them.
    def unique_strings(values)
      seen = {}

      Array(values).filter_map do |value|
        next unless value.is_a?(String)

        text = normalize_text(value)
        next if text.empty? || seen[text]

        seen[text] = true
        text
      end
    end

    # Always nil, so a caller can `return discard(...)` and drop the entry in one line.
    def discard(reason)
      @discarded << reason
      nil
    end

    # Anything that is not a string normalizes to empty rather than through to_s, which
    # would have published a numeric title as "42".
    def normalize_text(value)
      return "" unless value.is_a?(String)

      value.strip.gsub(/\s+/, " ")
    end
  end
end
