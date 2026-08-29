module TestPlan
  module DependencyDelta
    module GitLocator
      module_function

      # Accepts the several shapes a Git dependency is recorded in: a bundler GIT remote,
      # a `git+https://.../repo.git#sha` yarn locator, and the codeload tarball URL yarn v1
      # writes for `github:owner/repo#ref`.
      def repository(locator)
        value = locator.to_s
        codeload = value.match(%r{codeload\.github\.com/([^/]+)/([^/]+)/(?:tar\.gz|zip)/})
        return "#{codeload[1]}/#{codeload[2]}" if codeload

        match = value.match(%r{github\.com[:/]([^/]+)/([^/#]+?)(?:\.git)?(?:#|\z)})
        match && "#{match[1]}/#{match[2]}"
      end
    end
  end
end
