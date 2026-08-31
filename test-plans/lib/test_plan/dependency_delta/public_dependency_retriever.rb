require "fileutils"
require "tmpdir"
require "uri"
require_relative "./git_locator"
require_relative "./public_origin"
require_relative "./public_downloader"
require_relative "./safe_tar_extractor"
require_relative "./source_diff"
require_relative "./source_diff_builder"

module TestPlan
  module DependencyDelta
    class PublicRetriever
      def initialize(downloader: PublicDownloader.new, extractor: SafeTarExtractor.new)
        @downloader = downloader
        @extractor = extractor
      end

      def retrieve(change)
        Dir.mktmpdir("test-plan-dependency") do |directory|
          old_root = File.join(directory, "old")
          new_root = File.join(directory, "new")
          FileUtils.mkdir_p([old_root, new_root])

          case change.source
          when "rubygems"
            retrieve_gems(change, directory, old_root, new_root)
          when "npm"
            retrieve_npm(change, directory, old_root, new_root)
          when "git"
            retrieve_git(change, directory, old_root, new_root)
          when "mixed"
            raise "#{change.name} moved between a Git source and a registry, so its old " \
              "and new artifacts are not comparable; no source delta was retrieved"
          else
            raise "Unsupported public dependency source: #{change.source}"
          end

          SourceDiffBuilder.new.build(*content_roots(change.source, old_root, new_root))
        end
      end

    private

      # A gem is only the public gem if the lockfile actually resolved it from rubygems.org.
      # Gemfile.lock carries no checksum we could fall back on, so anything else is treated
      # as a private source and reported rather than guessed at.
      def retrieve_gems(change, directory, old_root, new_root)
        PublicOrigin.rubygems_public!(change)

        old_archive = File.join(directory, "old.gem")
        new_archive = File.join(directory, "new.gem")
        @downloader.download(rubygem_url(change.name, change.old_version), old_archive)
        @downloader.download(rubygem_url(change.name, change.new_version), new_archive)
        @extractor.extract_gem(old_archive, old_root)
        @extractor.extract_gem(new_archive, new_root)
      end

      def retrieve_npm(change, directory, old_root, new_root)
        old_tarball = public_npm_tarball(change, change.old_version, change.old_locator, change.old_integrity)
        new_tarball = public_npm_tarball(change, change.new_version, change.new_locator, change.new_integrity)

        old_archive = File.join(directory, "old.tgz")
        new_archive = File.join(directory, "new.tgz")
        @downloader.download(old_tarball, old_archive)
        @downloader.download(new_tarball, new_archive)
        @extractor.extract_gzip(old_archive, old_root)
        @extractor.extract_gzip(new_archive, new_root)
      end

      # Packages resolved straight from npm are public by definition. A package resolved
      # through a private registry may still be a proxied copy of the public one, so accept
      # it only when the lockfile's own checksum matches the public artifact -- otherwise we
      # would hand the provider a same-named package's unrelated source.
      def public_npm_tarball(change, version, locator, integrity)
        dist = @downloader.npm_dist(change.name, version)
        PublicOrigin.npm_public!(change, version, dist, locator, integrity)

        dist.fetch("tarball")
      end

      # Each revision has to come from the repository that actually recorded it. When a
      # dependency moves to a fork or a transferred repository, fetching the old revision
      # from the new repository 404s and loses a delta that is public on both sides.
      def retrieve_git(change, directory, old_root, new_root)
        old_repository = github_repository(change.old_locator) || github_repository(change.new_locator)
        new_repository = github_repository(change.new_locator) || github_repository(change.old_locator)
        unless old_repository && new_repository
          raise "Git dependency is not a public GitHub repository"
        end

        old_archive = File.join(directory, "old.tgz")
        new_archive = File.join(directory, "new.tgz")
        @downloader.download(github_archive_url(old_repository, change.old_version), old_archive)
        @downloader.download(github_archive_url(new_repository, change.new_version), new_archive)
        @extractor.extract_gzip(old_archive, old_root)
        @extractor.extract_gzip(new_archive, new_root)
      end

      def rubygem_url(name, version)
        "https://rubygems.org/downloads/#{URI.encode_www_form_component(name)}-#{URI.encode_www_form_component(version)}.gem"
      end

      def github_repository(locator)
        GitLocator.repository(locator)
      end

      def github_archive_url(repository, revision)
        "https://codeload.github.com/#{repository}/tar.gz/#{URI.encode_www_form_component(revision)}"
      end

      # npm tarballs wrap their contents in "package/" and GitHub archives in
      # "<repo>-<revision>/"; a gem's data archive has no wrapper at all. Descending
      # whenever a root happened to hold a single directory meant a gem containing only
      # "lib/" was entered, and -- worse -- one side could be entered while the other was
      # not, offsetting the two roots so every file read as removed and re-added. Strip a
      # wrapper only for the sources that have one, and only when both sides agree.
      def content_roots(source, old_root, new_root)
        return [old_root, new_root] if source == "rubygems"

        old_wrapper = wrapper_directory(old_root)
        new_wrapper = wrapper_directory(new_root)
        return [old_root, new_root] unless old_wrapper && new_wrapper

        [old_wrapper, new_wrapper]
      end

      def wrapper_directory(root)
        entries = Dir.children(root)
        return unless entries.length == 1

        candidate = File.join(root, entries.first)
        candidate if File.directory?(candidate)
      end
    end
  end
end
