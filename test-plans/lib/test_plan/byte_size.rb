module TestPlan
  # Renders a byte limit the way the constant means it, so a message never contradicts
  # the limit it is reporting -- including when a spec stubs the constant smaller.
  module ByteSize
    module_function

    def describe(bytes)
      return "#{bytes / (1024 * 1024)} MiB" if bytes >= 1024 * 1024
      return "#{bytes / 1024} KiB" if bytes >= 1024

      "#{bytes} bytes"
    end
  end
end
