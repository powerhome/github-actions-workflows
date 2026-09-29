# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"
require "uri"

require_relative "../runner_text"

require_relative "git_locator"
require_relative "public_downloader"
require_relative "public_origin"
require_relative "source_diff"
require_relative "source_diff_builder"
require_relative "version_spelling"

module TestPlan
  module DependencyDelta
    # The highest-signal artifact for a QA plan: it names behaviour changes in product
    # terms where a source diff leaves intent to be inferred. Read from the repository
    # because published packages routinely omit it -- neither the playbook_ui gem nor the
    # playbook-ui tarball ships one.
    #
    # Diffed rather than parsed, so no project's heading convention has to be understood.
    class ChangelogSource
      FILENAMES = %w[CHANGELOG.md CHANGELOG.markdown CHANGELOG CHANGES.md HISTORY.md].freeze
      DEFAULT_REF = "HEAD".freeze
      # A diff larger than a dependency's context budget is dropped whole, so cap it and
      # keep the head -- the newest release, in the newest-first layout nearly every
      # changelog uses. The artifact keeps the whole diff.
      MAX_DIFF_BYTES = 64 * 1024
      TRUNCATION_NOTICE = "\n[The changelog diff was truncated here; see the full-delta artifact.]\n".freeze

      def initialize(downloader: PublicDownloader.new)
        @downloader = downloader
      end

      # Never raises: missing evidence is not a failed run.
      def diffs_for(change)
        repository, candidates = resolve_source(change)
        return [] if repository.nil? || candidates.empty?

        old_ref = resolve_tag(repository, candidates, change.old_version)
        return [] unless old_ref

        old_body, path = fetch_any(repository, candidates, old_ref)
        return [] unless old_body

        baseline, new_body, bounded = compare(change, repository, path, old_body)
        return [] unless baseline && new_body && baseline != new_body

        diff = unified_diff(path, baseline, new_body)
        return [] if diff.nil?

        diff = unbounded_notice(change) + diff unless bounded

        [
          SourceDiff.new(
            path:,
            diff:,
            context_diff: truncate(diff),
            priority: SourceDiffBuilder::PRIORITY_CHANGELOG
          ),
        ]
      rescue => e
        warn "[test_plan] Changelog lookup skipped for #{change.name}: #{e.message}"
        []
      end

    private

      # Returns [baseline, new side, bounded?]. Which refs bracket the upgrade depends on
      # when the project commits its changelog, which the upgraded-to tag reveals:
      # committed before tagging, that tag describes its own release and the two tags
      # bracket it exactly; committed after tagging, it holds everything up to but not
      # including its own release, making it the baseline rather than the new side, with
      # the default branch supplying the notes plus anything released since.
      def compare(change, repository, path, old_body)
        if change.source == "git"
          return [old_body, fetch(repository, change.new_version.to_s, path), true]
        end

        target_ref = resolve_tag(repository, [path], change.new_version)
        target = target_ref && fetch(repository, target_ref, path)
        return [old_body, target, true] if target && describes?(target, change.new_version)

        head = fetch(repository, DEFAULT_REF, path)
        return [target, head, false] if target

        [old_body, head, false]
      end

      def unbounded_notice(change)
        "[These notes were read from the default branch, because this project commits " \
          "its changelog after tagging a release. Entries for releases later than " \
          "#{change.new_version} may appear below and are not part of this upgrade.]\n\n"
      end

      # npm records the repository and a monorepo's subdirectory. RubyGems exposes it
      # only through source_code_uri or changelog_uri, the latter naming the file rather
      # than leaving its location to be guessed -- playbook keeps its under playbook/.
      def resolve_source(change)
        case change.source
        when "npm"
          repository, directory = npm_repository(change)
          [repository, candidate_paths(directory)]
        when "rubygems"
          repository, path = rubygems_repository(change)
          [repository, [path, *candidate_paths(nil)].compact.uniq]
        when "git"
          repository = GitLocator.repository(change.new_locator) ||
                       GitLocator.repository(change.old_locator)
          [repository, candidate_paths(nil)]
        else
          [nil, []]
        end
      end

      def candidate_paths(directory)
        FILENAMES.map { |name| directory ? "#{directory}/#{name}" : name }
      end

      # Both sides are checked, because a changelog survives a refused download: a private
      # package sharing a name with a public one would otherwise be handed the unrelated
      # project's release notes exactly when source retrieval had already refused it.
      def npm_repository(change)
        payload = fetch_json(
          "https://registry.npmjs.org/#{URI.encode_www_form_component(change.name)}/" \
            "#{URI.encode_www_form_component(change.new_version)}"
        )
        unless PublicOrigin.npm_public?(payload["dist"].to_h, change.new_locator, change.new_integrity)
          return [nil, nil]
        end
        return [nil, nil] unless old_version_public?(change)

        repository = payload["repository"]
        return [nil, nil] unless repository.is_a?(Hash)

        [GitLocator.repository(repository["url"]), presence(repository["directory"])]
      end

      def old_version_public?(change)
        payload = fetch_json(
          "https://registry.npmjs.org/#{URI.encode_www_form_component(change.name)}/" \
            "#{URI.encode_www_form_component(change.old_version)}"
        )
        PublicOrigin.npm_public?(payload["dist"].to_h, change.old_locator, change.old_integrity)
      rescue
        false
      end

      def rubygems_repository(change)
        # Gemfile.lock carries no checksum, so a gem resolved from anywhere but
        # rubygems.org cannot be shown to be the public gem of that name.
        return [nil, nil] unless PublicOrigin.rubygems_public?(change)

        payload = fetch_json(
          "https://rubygems.org/api/v1/gems/#{URI.encode_www_form_component(change.name)}.json"
        )

        # A changelog_uri pointing at a blob gives the path as well as the repository.
        blob = GitLocator.blob(payload["changelog_uri"])
        return blob if blob

        %w[source_code_uri changelog_uri homepage_uri].each do |field|
          repository = GitLocator.repository(payload[field])
          return [repository, nil] if repository
        end
        [nil, nil]
      end

      # Tags are named in the repository's spelling, not RubyGems', and conventions vary
      # within one project: playbook publishes 17.0.0 and v17.1.0-rc.4 side by side.
      def resolve_tag(repository, candidates, version)
        refs = VersionSpelling.spellings(version).flat_map { |spelling| [spelling, "v#{spelling}"] }
        refs.find do |ref|
          candidates.any? { |path| fetch(repository, ref, path) }
        end
      end

      # Whether the tagged changelog already covers the release being tested.
      def describes?(body, version)
        VersionSpelling.spellings(version).any? { |spelling| body.include?(spelling) }
      end

      def fetch_any(repository, candidates, ref)
        candidates.each do |path|
          body = fetch(repository, ref, path)
          return [body, path] if body
        end
        [nil, nil]
      end

      def fetch(repository, ref, path)
        url = "https://raw.githubusercontent.com/#{repository}/#{URI.encode_www_form_component(ref)}/#{path}"
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
            unless [0, 1].include?(status.exitstatus)
              raise "diff failed for #{path}: #{RunnerText.utf8(stderr).strip}"
            end

            stdout = RunnerText.utf8(stdout)
            stdout.empty? ? nil : stdout
          end
        end
      end

      def truncate(diff)
        return diff if diff.bytesize <= MAX_DIFF_BYTES

        diff.byteslice(0, MAX_DIFF_BYTES).scrub + TRUNCATION_NOTICE
      end

      def presence(value)
        value.to_s.empty? ? nil : value.to_s
      end
    end
  end
end
