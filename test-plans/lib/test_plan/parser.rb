require "json"

module TestPlan
  class Parser
    VALID_PERMISSION_REQUIREMENTS = %w[yes no not_identified].freeze
    DEFAULT_FEATURE_CODE = "AC"
    FEATURE_CODE_PATTERN = /\A[A-Z][A-Z0-9]{1,5}\z/

    attr_reader :permissions, :feature_areas, :regression_tests, :discarded

    def self.parse_file(path)
      new(File.read(path, encoding: Encoding::UTF_8))
    end

    def initialize(json_string)
      @discarded = []
      @payload = JSON.parse(extract_json(json_string))
      validate_root!
      @permissions = build_permissions
      @feature_areas = build_feature_areas
      @regression_tests = build_regression_tests
    end

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

    def validate_root!
      raise "Test-plan JSON root must be a JSON object" unless @payload.is_a?(Hash)
      raise 'Test-plan JSON must include a "permissions" object' unless @payload["permissions"].is_a?(Hash)
      unless @payload.dig("permissions", "roles").is_a?(Array)
        raise 'Test-plan permissions must include a "roles" array'
      end
      unless @payload.dig("permissions", "subject_actions").is_a?(Array)
        raise 'Test-plan permissions must include a "subject_actions" array'
      end
      unless @payload.dig("permissions", "changes").is_a?(Array)
        raise 'Test-plan permissions must include a "changes" array'
      end
      raise 'Test-plan JSON must include a "feature_areas" array' unless @payload["feature_areas"].is_a?(Array)
      unless @payload["regression_tests"].is_a?(Array)
        raise 'Test-plan JSON must include a "regression_tests" array'
      end
    end

    def build_permissions
      raw = @payload.fetch("permissions")
      required = normalize_text(raw["required"]).downcase.tr(" -", "_")
      required = "not_identified" unless VALID_PERMISSION_REQUIREMENTS.include?(required)

      {
        "required" => required,
        "roles" => unique_strings(raw.fetch("roles")),
        "subject_actions" => permission_pairs(raw.fetch("subject_actions")),
        "changes" => unique_strings(raw.fetch("changes")),
      }
    end

    def build_feature_areas
      @payload.fetch("feature_areas").each_with_index.filter_map do |entry, index|
        build_feature_area(entry, index + 1)
      end
    end

    # A malformed part of the response is dropped rather than failing the whole run: one
    # unusable scenario should not cost a plan that is otherwise sound. What it must not
    # do is disappear quietly, so every discard is recorded and the rendered plan says
    # how much of the response could not be used.
    def build_feature_area(entry, position)
      unless entry.is_a?(Hash)
        return discard("feature area #{position} was not an object")
      end

      test_path = normalize_text(entry["test_path"])
      scenarios = Array(entry["scenarios"]).each_with_index.filter_map do |scenario, index|
        build_scenario(scenario, "#{position}.#{index + 1}")
      end
      return discard("feature area #{position} had no test_path") if test_path.empty?
      return discard("feature area #{position} (#{test_path}) had no usable scenarios") if scenarios.empty?

      {
        "test_path" => test_path,
        "domain" => normalize_text(entry["domain"]),
        "code" => normalize_feature_code(entry["code"]),
        "scenarios" => scenarios,
      }
    end

    def build_scenario(entry, position)
      return discard("scenario #{position} was not an object") unless entry.is_a?(Hash)

      title = normalize_text(entry["title"])
      steps = string_list(entry["steps"])
      return discard("scenario #{position} had no title") if title.empty?
      return discard("scenario #{position} (#{title}) had no steps array of strings") if steps.nil?
      return discard("scenario #{position} (#{title}) had no steps") if steps.empty?

      {
        "title" => title,
        "landing_page" => normalize_text(entry["landing_page"]),
        "audience" => normalize_text(entry["audience"]),
        "permissions" => permission_pairs(Array(entry["permissions"])),
        "include_in_regression" => entry["include_in_regression"] == true,
        "steps" => steps,
      }
    end

    def build_regression_tests
      seen = {}

      @payload.fetch("regression_tests").each_with_index.filter_map do |entry, index|
        next discard("regression test #{index + 1} was not an object") unless entry.is_a?(Hash)

        text = normalize_text(entry["text"])
        next if text.empty? || seen[text]

        seen[text] = true
        {
          "text" => text,
          "details" => unique_strings(Array(entry["details"])),
        }
      end
    end

    def normalize_feature_code(value)
      code = normalize_text(value).upcase
      FEATURE_CODE_PATTERN.match?(code) ? code : DEFAULT_FEATURE_CODE
    end

    def permission_pairs(values)
      seen = {}

      values.filter_map do |value|
        next unless value.is_a?(Hash)

        subject = normalize_text(value["subject"])
        action = normalize_text(value["action"])
        key = [subject, action]
        next if subject.empty? || action.empty? || seen[key]

        seen[key] = true
        {
          "subject" => subject,
          "action" => action,
        }
      end
    end

    # Steps are the plan's instructions, and the schema says they are strings. Coercing
    # anything else produces a published step reading {"x"=>1}, which is worse than
    # dropping the scenario and saying so. Returns nil when the value is not an array of
    # strings, so the caller can record why it went.
    def string_list(values)
      return nil unless values.is_a?(Array)
      return nil unless values.all? { |value| value.is_a?(String) }

      unique_strings(values)
    end

    # Supporting collections -- roles, details, permission changes -- drop what they
    # cannot use rather than discarding the entry around them.
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
    # would have published a numeric title as "42" and an object-valued regression text
    # as Ruby inspect output. Empty is what the existing paths already handle: a
    # scenario without a title is discarded, a landing page without one reads as not
    # identified, a permission pair without both halves is dropped.
    def normalize_text(value)
      return "" unless value.is_a?(String)

      value.strip.gsub(/\s+/, " ")
    end
  end
end
