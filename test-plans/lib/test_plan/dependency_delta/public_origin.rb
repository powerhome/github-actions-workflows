require "uri"

module TestPlan
  module DependencyDelta
    # Whether a lockfile entry really is the public package of that name and version.
    #
    # Name and version alone do not establish it: a private package can share both with
    # an unrelated public one. Anything downloaded on that assumption -- an archive, or
    # a repository's changelog -- would describe a different project entirely, which is
    # worse than having no evidence, because it reads as though it belongs.
    #
    # Every caller that resolves a dependency to something public goes through here, so
    # the rule is stated once.
    module PublicOrigin
      module_function

      PUBLIC_RUBYGEMS_HOSTS = %w[rubygems.org].freeze
      # registry.yarnpkg.com is an alias of registry.npmjs.org.
      PUBLIC_NPM_HOSTS = %w[registry.npmjs.org registry.yarnpkg.com].freeze

      # Gemfile.lock carries no checksum, so the remote is the only evidence there is.
      def rubygems_public?(change)
        [change.old_locator, change.new_locator].all? do |locator|
          host?(locator, PUBLIC_RUBYGEMS_HOSTS)
        end
      end

      def rubygems_public!(change)
        return if rubygems_public?(change)

        raise "#{change.name} resolves to a non-public RubyGems source " \
          "(#{describe(change.new_locator)}); private sources are not retrieved"
      end

      # A package resolved through a private registry may still be a proxied copy of the
      # public one, which the lockfile's own checksum can prove.
      def npm_public?(dist, locator, integrity)
        return true if host?(locator, PUBLIC_NPM_HOSTS)

        checksum_matches?(dist, locator, integrity)
      end

      def npm_public!(change, version, dist, locator, integrity)
        return if npm_public?(dist, locator, integrity)

        raise "#{change.name}@#{version} resolves to a non-public registry " \
          "(#{describe(locator)}) and its lockfile checksum does not match the public " \
          "package; private sources are not retrieved"
      end

      def checksum_matches?(dist, locator, integrity)
        return true if !integrity.to_s.empty? && integrity == dist["integrity"]

        # Older yarn v1 entries carry no integrity line and record a sha1 fragment.
        fragment = locator.to_s.split("#", 2)[1].to_s
        !fragment.empty? && fragment == dist["shasum"]
      end

      def host?(locator, hosts)
        uri = URI.parse(locator.to_s)
        uri.is_a?(URI::HTTPS) && hosts.include?(uri.host)
      rescue URI::InvalidURIError
        false
      end

      def describe(locator)
        return "unknown" if locator.to_s.empty?

        URI.parse(locator.to_s).host || locator.to_s
      rescue URI::InvalidURIError
        locator.to_s
      end
    end
  end
end
