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
      # Past this a list stops being a set of pages to visit and becomes noise; the count
      # still tells the model the kit is everywhere.
      MAX_LISTED_FILES = 25
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
        @failures = []
      end

      # Called for every dependency the generator retrieves; ignores all but Playbook.
      def observe(change, diffs)
        return unless @workspace
        return unless PACKAGE_NAMES.include?(change.name)

        diffs.each do |diff|
          kit = diff.path[KIT_PATH, 1]
          next unless kit

          (@kits[kit] ||= []) << "#{change.ecosystem}:#{change.name}"
        end
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

          A kit used in more than #{MAX_LISTED_FILES} files is reported as a count only. Those are
          shared building blocks; cover a representative page rather than every one.

          #{sections.join("\n")}
        REPORT
      end

    private

      def section(kit)
        files = usage(kit)
        return "#{titled(kit)} — search failed\n\n#{SEARCH_FAILED}\n" if files.nil?

        heading = "#{titled(kit)} — #{files.length} #{files.length == 1 ? "file" : "files"}"

        return "#{heading}\n\nUsed too widely to list. Cover a representative page.\n" if files.length > MAX_LISTED_FILES
        return "#{heading}\n\nNo usage found in this repository.\n" if files.empty?

        "#{heading}\n\n#{files.map { |file| "- #{file}" }.join("\n")}\n"
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
