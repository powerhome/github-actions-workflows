module TestPlan
  module DependencyDelta
    # `name` is the package the lockfile actually installed, which is what evidence has
    # to be fetched for. `alias` is the name the manifest asked for, which is what a
    # package.json dependency or a workspace member is listed under. For everything
    # except an npm alias the two are the same.
    YarnRecord = Struct.new(:name, :alias, :version, :resolved, :integrity, keyword_init: true) do
      def initialize(**attributes)
        super
        self.alias ||= name
      end
    end

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
          package_names(selectors).each do |requested, installed|
            if version
              output << YarnRecord.new(
                name: installed,
                alias: requested,
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

      # Returns [requested name, installed name] pairs. They differ only for an npm
      # alias -- `alias-name@npm:real-package@^1` installs real-package while the
      # manifest asks for alias-name. Fetching evidence for the alias would download an
      # unrelated package that happens to bear that name.
      def package_names(selectors)
        selectors.filter_map do |selector|
          requested, descriptor = split_selector(selector)
          next unless requested

          [requested, installed_name(descriptor) || requested]
        end.uniq
      end

      def split_selector(selector)
        if selector.start_with?("@")
          separator = selector.index("@", 1)
          separator ? [selector[0...separator], selector[(separator + 1)..]] : [nil, nil]
        else
          name, descriptor = selector.split("@", 2)
          [name, descriptor]
        end
      end

      def installed_name(descriptor)
        target = descriptor.to_s[/\Anpm:(.+)\z/, 1]
        return nil unless target

        split_selector(target).first
      end
    end
  end
end
