require "json"
require "open3"
require "tempfile"
require "uri"

require_relative "git_locator"
require_relative "public_downloader"
require_relative "source_diff"
require_relative "source_diff_builder"

module TestPlan
  module DependencyDelta
    # Published packages routinely omit the changelog: neither the playbook_ui gem nor
    # the playbook-ui tarball ships one, though the repository keeps a detailed file.
    # For a manual QA plan that file is the single highest-signal artifact available --
    # it names behaviour changes in product terms, where a source diff only shows the
    # code and leaves the model to infer intent.
    #
    # So fetch it from the repository instead. The old side is read at the upgraded-from
    # tag and the new side at the default branch rather than the upgraded-to tag,
    # because a generated changelog is usually committed after its release is tagged --
    # playbook's 17.1.0 tag still describes 17.0.0 as the newest release. Reading the
    # default branch trades a chance of including unreleased notes for not missing the
    # release being tested.
    #
    # Diffing the two files rather than parsing them keeps this format-agnostic; no
    # project's heading convention has to be understood.
    class ChangelogSource
      FILENAMES = %w[CHANGELOG.md CHANGELOG.markdown CHANGELOG CHANGES.md HISTORY.md].freeze
      DEFAULT_REF = "HEAD".freeze
      # A single diff larger than a dependency's context budget is dropped whole, so
      # cap it here instead and keep the head, which is the newest release in the
      # newest-first layout nearly every changelog uses.
      MAX_DIFF_BYTES = 64 * 1024
      TRUNCATION_NOTICE = "\n[The changelog diff was truncated here; see the full-delta artifact.]\n".freeze

      def initialize(downloader: PublicDownloader.new)
        @downloader = downloader
      end

      # Never raises: a missing repository, tag, or changelog is an absence of evidence,
      # not a failure of the run.
      def diffs_for(change)
        repository, directory = resolve_repository(change)
        return [] unless repository

        old_ref = resolve_tag(repository, directory, change.old_version)
        return [] unless old_ref

        old_body, path = fetch_any(repository, directory, old_ref)
        return [] unless old_body

        new_body = fetch(repository, directory, DEFAULT_REF, File.basename(path))
        return [] unless new_body && new_body != old_body

        diff = unified_diff(path, old_body, new_body)
        return [] if diff.nil?

        [SourceDiff.new(path: path, diff: diff, priority: SourceDiffBuilder::PRIORITY_CHANGELOG)]
      rescue => e
        warn "[test_plan] Changelog lookup skipped for #{change.name}: #{e.message}"
        []
      end

    private

      # npm records the repository, and a monorepo's subdirectory with it. RubyGems
      # exposes it only when a gem sets source_code_uri or changelog_uri -- playbook_ui
      # sets neither, which is why the gem half relies on its npm counterpart being
      # linked to the same release.
      def resolve_repository(change)
        case change.source
        when "npm" then npm_repository(change)
        when "rubygems" then [rubygems_repository(change), nil]
        when "git" then [GitLocator.repository(change.new_locator) ||
          GitLocator.repository(change.old_locator), nil]
        else [nil, nil]
        end
      end

      def npm_repository(change)
        payload = fetch_json(
          "https://registry.npmjs.org/#{URI.encode_www_form_component(change.name)}/" \
            "#{URI.encode_www_form_component(change.new_version)}"
        )
        repository = payload["repository"]
        return [nil, nil] unless repository.is_a?(Hash)

        [GitLocator.repository(repository["url"]), presence(repository["directory"])]
      end

      def rubygems_repository(change)
        payload = fetch_json(
          "https://rubygems.org/api/v1/gems/#{URI.encode_www_form_component(change.name)}.json"
        )
        %w[source_code_uri changelog_uri homepage_uri].each do |field|
          repository = GitLocator.repository(payload[field])
          return repository if repository
        end
        nil
      end

      # Tag conventions vary even within one project; playbook publishes 17.0.0 and
      # v17.1.0-rc.4 side by side.
      def resolve_tag(repository, directory, version)
        ["#{version}", "v#{version}"].find do |candidate|
          FILENAMES.any? { |name| fetch(repository, directory, candidate, name) }
        end
      end

      def fetch_any(repository, directory, ref)
        FILENAMES.each do |name|
          body = fetch(repository, directory, ref, name)
          return [body, join(directory, name)] if body
        end
        [nil, nil]
      end

      def fetch(repository, directory, ref, name)
        url = "https://raw.githubusercontent.com/#{repository}/#{URI.encode_www_form_component(ref)}/" \
          "#{join(directory, name)}"
        Tempfile.create(["changelog", ".md"]) do |file|
          @downloader.download(url, file.path)
          body = File.read(file.path, encoding: Encoding::UTF_8)
          body.empty? ? nil : body
        end
      rescue
        nil
      end

      def fetch_json(url)
        Tempfile.create(["metadata", ".json"]) do |file|
          @downloader.download(url, file.path)
          JSON.parse(File.read(file.path, encoding: Encoding::UTF_8))
        end
      end

      def unified_diff(path, old_body, new_body)
        Tempfile.create("changelog-old") do |old_file|
          Tempfile.create("changelog-new") do |new_file|
            old_file.write(old_body)
            new_file.write(new_body)
            [old_file, new_file].each(&:flush)

            stdout, stderr, status = Open3.capture3(
              "diff", "-u", "--label", "a/#{path}", "--label", "b/#{path}",
              old_file.path, new_file.path
            )
            raise "diff failed for #{path}: #{stderr.strip}" unless [0, 1].include?(status.exitstatus)

            truncate(stdout)
          end
        end
      end

      def truncate(diff)
        return nil if diff.empty?
        return diff if diff.bytesize <= MAX_DIFF_BYTES

        diff.byteslice(0, MAX_DIFF_BYTES).scrub + TRUNCATION_NOTICE
      end

      def join(directory, name)
        directory ? "#{directory}/#{name}" : name
      end

      def presence(value)
        value.to_s.empty? ? nil : value.to_s
      end
    end
  end
end
