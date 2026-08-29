require "uri"

module TestPlan
  module DependencyDelta
    # Reads owner/repo out of the several shapes a Git dependency is recorded in: a
    # bundler GIT remote, a `git+https://.../repo.git#sha` yarn locator, the codeload
    # tarball URL yarn v1 writes for `github:owner/repo#ref`, and the SCP form.
    #
    # The host is matched exactly rather than looked for inside the string. Substring
    # matching accepted https://evilgithub.com/example/widget.git as example/widget, and
    # retrieval would then have attached a real, unrelated repository's source and
    # changelog to the dependency.
    module GitLocator
      module_function

      HOSTS = %w[github.com www.github.com codeload.github.com].freeze
      SCP = %r{\Agit@([^:/]+):([^/]+)/(.+)\z}

      def repository(locator)
        owner, name = owner_and_name(locator)
        return nil unless owner && name

        "#{owner}/#{name}"
      end

      # A changelog_uri points at a blob, which names the file as well as the repository:
      # https://github.com/owner/repo/blob/<ref>/<path>
      def blob(locator)
        uri = parsed(locator)
        return nil unless uri

        segments = path_segments(uri)
        return nil unless segments.length >= 5 && segments[2] == "blob"

        ["#{segments[0]}/#{strip_git(segments[1])}", segments[4..].join("/")]
      end

      def owner_and_name(locator)
        value = locator.to_s.sub(/\Agit\+/, "")

        if (scp = value.match(SCP))
          return nil unless HOSTS.include?(scp[1])

          return [scp[2], strip_git(scp[3].split("/").first)]
        end

        uri = parsed(value)
        return nil unless uri

        segments = path_segments(uri)
        return nil if segments.length < 2

        [segments[0], strip_git(segments[1])]
      end

      def parsed(value)
        uri = URI.parse(value.to_s.sub(/\Agit\+/, ""))
        HOSTS.include?(uri.host) ? uri : nil
      rescue URI::InvalidURIError
        nil
      end

      def path_segments(uri)
        uri.path.to_s.split("/").reject(&:empty?)
      end

      def strip_git(name)
        name.to_s.sub(/\.git\z/, "")
      end
    end
  end
end
