module TestPlan
  # Text crossing the runner boundary: subprocess bytes need a predictable encoding,
  # and size limits need the same units in exceptions and workflow messages.
  module RunnerText
    module_function

    def utf8(text)
      text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end

    def human_size(bytes)
      return "#{bytes / (1024 * 1024)} MiB" if bytes >= 1024 * 1024
      return "#{bytes / 1024} KiB" if bytes >= 1024

      "#{bytes} bytes"
    end
  end
end
