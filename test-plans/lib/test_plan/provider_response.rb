require "json"

module TestPlan
  # The provider answers with JSON somewhere inside prose, and nothing it returns can be
  # trusted to be the type the schema says. Includers set @discarded before parsing.
  module ProviderResponse
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

    # nil unless every value is a string, so the caller can record why the entry went:
    # coercing instead publishes a step reading {"x"=>1}.
    def string_list(values)
      return nil unless values.is_a?(Array)
      return nil unless values.all? { |value| value.is_a?(String) }

      unique_strings(values)
    end

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

    # Shared so a response cannot be usable in one plan shape and not another for a reason
    # nobody chose. `dependency: true` also requires each case to name what it tests, which
    # only the dependency plan groups by.
    def check_list(entries, label, dependency: false)
      unless entries.is_a?(Array)
        discard("#{label} list was not an array")
        return []
      end

      entries.each_with_index.filter_map do |entry, index|
        next discard("#{label} #{index + 1} was not an object") unless entry.is_a?(Hash)

        title = normalize_text(entry["title"])
        steps = string_list(entry["steps"])
        next discard("#{label} #{index + 1} had no title or usable steps") if title.empty? || steps.nil? || steps.empty?

        check = { "title" => title, "page" => normalize_text(entry["page"]), "steps" => steps }
        next check unless dependency

        name = normalize_text(entry["dependency"])
        next discard("#{label} #{index + 1} named no dependency") if name.empty?

        check.merge("dependency" => name)
      end
    end

    # Always nil, so a caller can `return discard(...)` and drop the entry in one line.
    def discard(reason)
      @discarded << reason
      nil
    end

    # Empty rather than to_s, which would publish a numeric title as "42".
    def normalize_text(value)
      return "" unless value.is_a?(String)

      value.strip.gsub(/\s+/, " ")
    end
  end
end
