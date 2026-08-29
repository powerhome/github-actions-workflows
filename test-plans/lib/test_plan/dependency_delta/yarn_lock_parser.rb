module TestPlan
  module DependencyDelta
    YarnRecord = Struct.new(:name, :version, :resolved, :integrity, keyword_init: true)

    class YarnLockParser
      def initialize(content)
        @content = content.to_s
      end

      def records
        output = []
        selectors = []
        version = nil
        resolved = nil
        integrity = nil

        flush = lambda do
          package_names(selectors).each do |name|
            if version
              output << YarnRecord.new(
                name: name,
                version: version,
                resolved: resolved,
                integrity: integrity
              )
            end
          end
        end

        @content.each_line do |line|
          if !line.start_with?(" ", "#", "\n") && line.rstrip.end_with?(":")
            flush.call
            selectors = parse_selectors(line.rstrip.delete_suffix(":"))
            version = nil
            resolved = nil
            integrity = nil
          elsif (match = line.match(/^  version\s+"([^"]+)"/))
            version = match[1]
          elsif (match = line.match(/^  resolved\s+"([^"]+)"/))
            resolved = match[1]
          elsif (match = line.match(/^  integrity\s+(\S+)/))
            integrity = match[1].delete('"')
          end
        end
        flush.call
        output
      end

    private

      def parse_selectors(header)
        header.scan(/"([^"]+)"|([^,\s]+)/).map { |quoted, bare| quoted || bare }
      end

      def package_names(selectors)
        selectors.filter_map do |selector|
          if selector.start_with?("@")
            separator = selector.index("@", 1)
            selector[0...separator] if separator
          else
            selector.split("@", 2).first
          end
        end.uniq
      end
    end
  end
end
