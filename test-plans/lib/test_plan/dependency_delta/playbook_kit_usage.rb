require "open3"

require_relative "../command_output"

module TestPlan
  module DependencyDelta
    # A Playbook version bump is the PR shape this whole delta exists for, and it is the
    # one where pr.diff says least: every file in such a bump is a lockfile. The
    # changelog tells the model which kits moved, but not the only thing a tester needs
    # -- which pages to open.
    #
    # Answering that means resolving a kit across every call site in a large
    # application. The agent could search for them, but at that scale it is slow and
    # unreliable, so the search happens here and the answer is handed over as evidence.
    #
    # The kits are taken from the gem's own changed file paths rather than the changelog
    # prose: every kit lives in app/pb_kits/playbook/pb_<kit>/, which is exact, where
    # matching release-note headings is guesswork. On the 17.0.0 -> 17.1.0 delta the
    # paths yield materially more kits than the prose does.
    class PlaybookKitUsage
      PACKAGE_NAMES = %w[playbook_ui playbook-ui].freeze
      KIT_PATH = %r{(?:\A|/)app/pb_kits/playbook/pb_([a-z0-9_]+)/}
      # A kit used this few times can be covered exhaustively, and the plan says so. Past
      # it the plan tests a sample and says that instead, so SAMPLE_SIZE has to leave
      # enough call sites to choose a few representative ones from.
      COMPLETE_COVERAGE_MAX = 4
      SAMPLE_SIZE = 8
      SEARCHED_EXTENSIONS = %w[*.erb *.rb *.haml *.tsx *.jsx *.ts *.js].freeze
      SEARCH_FAILED = "The search for this kit could not be run, so this section says " \
        "nothing about whether the kit is used here. Treat it as possibly used and see " \
        "the workflow run log for the reason."

      def self.disabled
        new(workspace: nil)
      end

      def initialize(workspace:)
        @workspace = workspace
        @kits = {}
        @cross_cutting = []
        @failures = []
      end

      # Called for every dependency the generator retrieves; ignores all but Playbook.
      def observe(change, diffs)
        return unless @workspace
        return unless PACKAGE_NAMES.include?(change.name)

        diffs.each do |diff|
          kit = diff.path[KIT_PATH, 1]
          # A release changes more than kits -- tokens, global props, the pb_rails helper
          # layer -- and those apply to every page rather than one. Kept rather than
          # skipped, because nothing else in the plan can see them.
          next @cross_cutting << diff.path unless kit

          (@kits[kit] ||= []) << "#{change.ecosystem}:#{change.name}"
        end
      end

      # Changed paths that belong to no kit, build output excluded: it is compiled from
      # the source already listed and says nothing a tester can act on.
      def cross_cutting_paths
        @cross_cutting.reject { |path| path.match?(%r{(?:\A|/)dist/}) }.uniq.sort
      end

      # Empty unless the run raised Playbook, which is what shapes the plan by kit.
      def kits
        @kits.keys.sort
      end

      def report
        return nil if @kits.empty?

        sections = @kits.keys.sort.map { |kit| section(kit) }
        <<~REPORT
          # Playbook kits changed by this upgrade

          The upgrade changed #{@kits.length} #{@kits.length == 1 ? "kit" : "kits"}. Each section below
          lists where this repository uses that kit, so coverage can start from the pages
          a tester can actually open. Paths are repository-relative.

          A kit used in #{COMPLETE_COVERAGE_MAX} files or fewer can be covered exhaustively, and its section
          says so. A kit used more widely lists a sample of up to #{SAMPLE_SIZE} call sites alongside
          its true total; choose a few representative pages from the sample and say that
          is what they are.

          #{sections.join("\n")}
          #{cross_cutting_section}
        REPORT
      end

      # Named so the plan has somewhere to put a change that belongs to no kit rather than
      # attaching it to one it did not come from.
      def cross_cutting_section
        paths = cross_cutting_paths
        return "" if paths.empty?

        <<~SECTION
          ## Changes not scoped to a kit

          #{paths.length} changed #{paths.length == 1 ? "file" : "files"} belong to no kit. These apply across the
          application rather than to one page, so cover them separately from the kits.

          #{paths.first(SAMPLE_SIZE).map { |path| "- #{path}" }.join("\n")}
          #{paths.length > SAMPLE_SIZE ? "- ...and #{paths.length - SAMPLE_SIZE} more\n" : ""}
        SECTION
      end

    private

      def section(kit)
        files = usage(kit)
        return "#{titled(kit)} — search failed\n\n#{SEARCH_FAILED}\n" if files.nil?

        heading = "#{titled(kit)} — #{files.length} #{files.length == 1 ? "file" : "files"}"
        return "#{heading}\n\nNo usage found in this repository.\n" if files.empty?

        listed = files.first(SAMPLE_SIZE)
        coverage =
          if files.length <= COMPLETE_COVERAGE_MAX
            "Every use in this repository is listed. Cover all of them."
          else
            "Used in #{files.length} files. #{listed.length} of them are listed as a sample; " \
              "cover a few and say they are representative."
          end

        "#{heading}\n\n#{coverage}\n\n#{listed.map { |file| "- #{file}" }.join("\n")}\n"
      end

      # These are POSIX ERE for git grep, not Ruby regexps: \s and (?:...) are silently
      # unsupported there and match nothing at all, so they are written out longhand.
      #
      # Rails kits are called as pb_rails("kit"), pb_rails("kit/sub_template"), and for a
      # few kits pb_rails("pb_kit"). React kits are used as the camelized tag.
      def usage(kit)
        rails = %Q{pb_rails\\([[:space:]]*["'](pb_)?#{kit}["'/]}
        react = %Q{<#{camelize(kit)}[[:space:]/>]}

        found = [git_grep(rails), git_grep(react)]
        # Half a search reads exactly like a whole one once it is a list of paths, and the
        # half that ran is the half that says "no usage" loudest. An incomplete union is
        # reported as a failure rather than as the files that did come back.
        return nil if found.any?(&:nil?)

        found.reduce(:|).sort
      end

      # Returns nil rather than an empty list when the search could not run. The two are
      # opposite claims: no matches tells a tester there is nothing to open, which is the
      # conclusion this file exists to support, so asserting it on the strength of a
      # failed search is worse than saying nothing.
      def git_grep(pattern)
        stdout, stderr, status = Open3.capture3(
          "git", "grep", "--no-color", "-l", "-E", pattern, "--", *SEARCHED_EXTENSIONS,
          chdir: @workspace
        )
        # git grep exits 1 when nothing matched, which is not an error here.
        unless [0, 1].include?(status.exitstatus)
          record_failure("git grep exited #{status.exitstatus}: #{CommandOutput.utf8(stderr)}")
          return nil
        end

        CommandOutput.utf8(stdout).lines.map(&:chomp).reject(&:empty?)
      rescue => e
        record_failure("git grep could not be run: #{e.class}: #{e.message}")
        nil
      end

      # Annotated on the run rather than carried into the report: the reason comes from
      # git's stderr, which quotes paths out of the workspace, and the report is read by
      # the agent as evidence.
      def record_failure(detail)
        detail = detail.to_s.strip.lines.first.to_s.strip[0, 200].to_s
        return if @failures.include?(detail)

        @failures << detail
        puts("::warning::Playbook kit usage search failed: #{detail}")
      end

      def titled(kit)
        "## #{titleize(kit)} (`#{kit}`)"
      end

      def camelize(kit)
        kit.split("_").map(&:capitalize).join
      end

      def titleize(kit)
        kit.split("_").map(&:capitalize).join(" ")
      end
    end
  end
end
