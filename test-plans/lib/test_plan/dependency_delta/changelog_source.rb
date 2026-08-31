require "json"
require "open3"
require "tempfile"
require "uri"

require_relative "../command_output"

require_relative "git_locator"
require_relative "public_downloader"
require_relative "public_origin"
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
      # A single diff larger than a dependency's context budget is dropped whole, so cap
      # what the provider sees and keep the head, which is the newest release in the
      # newest-first layout nearly every changelog uses. The artifact keeps the whole
      # diff, so the notice below points somewhere the content actually is.
      MAX_DIFF_BYTES = 64 * 1024
      TRUNCATION_NOTICE = "\n[The changelog diff was truncated here; see the full-delta artifact.]\n".freeze

      def initialize(downloader: PublicDownloader.new)
        @downloader = downloader
      end

      # Never raises: a missing repository, tag, or changelog is an absence of evidence,
      # not a failure of the run.
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
            path: path,
            diff: diff,
            context_diff: truncate(diff),
            priority: SourceDiffBuilder::PRIORITY_CHANGELOG
          ),
        ]
      rescue => e
        warn "[test_plan] Changelog lookup skipped for #{change.name}: #{e.message}"
        []
      end

    private

      # Returns the baseline, the new side, and whether the pair is bounded by the
      # upgrade. Both ends matter: notes for the version already installed are as much
      # noise as notes for a version that is not.
      #
      # A Git-pinned dependency names both revisions, so it brackets itself.
      #
      # For a registry release the upgraded-to tag decides which pattern the project
      # follows, and the answer differs for each:
      #
      #   Changelog committed before tagging -- the tag already describes its own
      #   release, so the two tags bracket the upgrade exactly.
      #
      #   Committed after tagging -- the tag holds everything up to but not including
      #   its own release, which makes it the right *baseline*, not the new side.
      #   Reading from the upgraded-from tag instead would carry the old release's own
      #   notes, describing behaviour already installed. The default branch supplies the
      #   notes themselves, along with anything released since, which the notice says.
      def compare(change, repository, path, old_body)
        if change.source == "git"
          return [old_body, fetch(repository, change.new_version.to_s, path), true]
        end

        target_ref = resolve_tag(repository, [path], change.new_version)
        target = target_ref && fetch(repository, target_ref, path)
        return [old_body, target, true] if target && target.include?(change.new_version.to_s)

        head = fetch(repository, DEFAULT_REF, path)
        return [target, head, false] if target

        [old_body, head, false]
      end

      def unbounded_notice(change)
        "[These notes were read from the default branch, because this project commits " \
          "its changelog after tagging a release. Entries for releases later than " \
          "#{change.new_version} may appear below and are not part of this upgrade.]\n\n"
      end

      # Returns the repository and the changelog paths worth trying, in order.
      #
      # npm records the repository, and a monorepo's subdirectory with it. RubyGems
      # exposes it only when a gem sets source_code_uri or changelog_uri; a
      # changelog_uri is better still, because it names the file rather than leaving us
      # to guess that it sits at the repository root -- playbook keeps its under
      # playbook/.
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

      # The version document is only this package's if the lockfile entry is the public
      # package at all. Without that check a private package sharing a name with a
      # public one would be handed the unrelated project's changelog -- and it would be
      # handed it precisely when source retrieval had already refused the package for
      # the same reason, since a changelog survives a refused download.
      def npm_repository(change)
        payload = fetch_json(
          "https://registry.npmjs.org/#{URI.encode_www_form_component(change.name)}/" \
            "#{URI.encode_www_form_component(change.new_version)}"
        )
        # Both sides, not just the new one. The changelog diff starts at the old
        # version's tag, so an old entry that came from a private package would have
        # this repository's history presented as its release notes -- and would, since a
        # changelog survives the refused download of that side.
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

      # Tag conventions vary even within one project; playbook publishes 17.0.0 and
      # v17.1.0-rc.4 side by side.
      def resolve_tag(repository, candidates, version)
        ["#{version}", "v#{version}"].find do |ref|
          candidates.any? { |path| fetch(repository, ref, path) }
        end
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
              raise "diff failed for #{path}: #{CommandOutput.utf8(stderr).strip}"
            end

            stdout = CommandOutput.utf8(stdout)
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
