require "open3"

require_relative "../command_output"
require_relative "../playbook/kit_facts"
require_relative "../playbook/packages"
require_relative "./call_site_sample"

module TestPlan
  module DependencyDelta
    # Which pages to open is the one thing a tester needs and the changelog does not say.
    # Resolving a kit across every call site in a large application is slow and unreliable
    # for the agent to do itself, so it happens here and is handed over as evidence.
    #
    # Kits come from the gem's changed file paths, not the changelog prose: every kit
    # lives in app/pb_kits/playbook/pb_<kit>/, which is exact where matching release-note
    # headings is guesswork, and on the 17.0.0 -> 17.1.0 delta yields materially more.
    class PlaybookKitUsage
      KIT_PATH = %r{(?:\A|/)app/pb_kits/playbook/pb_([a-z0-9_]+)/}
      # At or under this the plan claims exhaustive coverage; past it, a sample. SAMPLE_SIZE
      # has to leave enough call sites to pick representative ones from.
      SAMPLE_SIZE = 8
      SEARCHED_EXTENSIONS = %w[*.erb *.rb *.haml *.tsx *.jsx *.ts *.js].freeze
      # A kit is two implementations sharing a name and a release usually moves one, so
      # naming which halves what a tester reopens. A stylesheet or an unrecognised
      # extension is reported as both rather than guessed: guessing wrong costs a system
      # nobody retests.
      RAILS_EXTENSIONS = %w[.rb .erb .haml].freeze
      REACT_EXTENSIONS = %w[.tsx .jsx .ts .js].freeze
      SEARCH_FAILED = "The search for this kit could not be run, so this section says " \
        "nothing about whether the kit is used here. Treat it as possibly used and see " \
        "the workflow run log for the reason."

      def self.disabled
        new(workspace: nil)
      end

      def initialize(workspace:)
        @workspace = workspace
        @kits = {}
        @evidence = {}
        @failures = []
      end

      def observe(change, diffs)
        return unless @workspace
        return unless Playbook::PACKAGE_NAMES.include?(change.name)

        diffs.each do |diff|
          # Playbook ships docs and tests inside the kit directory, so a release that only
          # refreshed the docs site reported the kit as changed.
          next unless diff.evidence?

          kit = diff.path[KIT_PATH, 1]
          next unless kit

          (@kits[kit] ||= []) << diff.path
        end
      end

      def kits
        @kits.keys.sort
      end

      def report
        return nil if @kits.empty?

        sections = @kits.keys.sort.map { |kit| section(kit) }
        <<~REPORT
          # Playbook kits changed by this upgrade

          The upgrade changed #{@kits.length} #{@kits.length == 1 ? "kit" : "kits"}. Each section below
          names which side of the kit the release touched -- the Rails helper, the React
          component, or both -- and lists where this repository calls that side, so
          coverage starts from pages a tester can actually open. Paths are
          repository-relative, and the call sites listed for a kit are deliberately spread
          across components.

          #{sections.join("\n")}
        REPORT
      end

      # Built from the same evidence as the report, so the plan and the provider cannot
      # disagree about a kit's coverage.
      def facts
        Playbook::KitFacts.document(
          @kits.keys.sort.map do |kit|
            evidence = evidence_for(kit)
            {
              slug: kit,
              name: titleize(kit),
              coverage: evidence.coverage,
              call_sites: evidence.call_sites,
              systems_changed: evidence.systems_changed,
              systems_in_use: evidence.systems_in_use,
            }
          end
        )
      end

    private

      # No counts here on purpose: the provider was once asked to copy one back and
      # reported a kit as used in 1083 files. The coverage sentence carries the same
      # decision with nothing to miscopy; counts stay in the facts file and the log.
      def section(kit)
        evidence = evidence_for(kit)
        heading = "#{titled(kit)} — changed in #{Playbook::KitFacts.systems_label(evidence.systems_changed)}"
        return "#{heading} · search failed\n\n#{SEARCH_FAILED}\n" unless evidence.searchable?

        sentence = Playbook::KitFacts.sentence(evidence.coverage)
        return "#{heading}\n\n#{sentence}\n" if evidence.systems_in_use.empty?

        body = evidence.systems_changed.map { |system| system_block(system, evidence) }

        "#{heading}\n\n#{sentence}\n\n#{body.join("\n")}"
      end

      def system_block(system, evidence)
        label = "**#{Playbook::KitFacts::SYSTEM_LABELS.fetch(system)} call sites**"
        paths = evidence.sampled(system)
        if paths.empty?
          return "#{label}\n\nThis upgrade changed the #{Playbook::KitFacts::SYSTEM_LABELS.fetch(system)} " \
            "side of this kit, but nothing in this repository renders it.\n"
        end

        "#{label}\n\n#{paths.map { |path| "- #{path}" }.join("\n")}\n"
      end

      KitEvidence = Struct.new(:systems_changed, :call_sites_by_system, keyword_init: true) do
        def searchable?
          call_sites_by_system.values.none?(&:nil?)
        end

        def systems_in_use
          systems_changed.select { |system| !call_sites_by_system[system].to_a.empty? }
        end

        # Only the systems the release touched, so a React-only change to a kit with two
        # React call sites and nine hundred Rails ones is still exhaustible.
        def call_sites
          systems_changed.flat_map { |system| call_sites_by_system[system].to_a }.uniq.length
        end

        def coverage
          Playbook::KitFacts.coverage(call_sites:, searchable: searchable?)
        end

        # Spread before the slice so the sample buys breadth rather than eight files from
        # whichever component sorts first; sorted after, for a stable reading order.
        def sampled(system)
          CallSiteSample.spread(call_sites_by_system[system].to_a).first(SAMPLE_SIZE).sort
        end
      end

      # Memoized: the report and the facts both need it, and a git grep over a monorepo
      # this size costs seconds.
      def evidence_for(kit)
        @evidence[kit] ||= begin
          systems = systems_changed(@kits.fetch(kit, []))
          KitEvidence.new(
            systems_changed: systems,
            call_sites_by_system: systems.to_h { |system| [system, usage(kit, system)] }
          )
        end
      end

      def systems_changed(paths)
        systems = paths.flat_map { |path| systems_for(path) }.uniq
        Playbook::KitFacts::SYSTEMS.select { |system| systems.include?(system) }
      end

      def systems_for(path)
        case File.extname(path).downcase
        when *RAILS_EXTENSIONS then ["rails"]
        when *REACT_EXTENSIONS then ["react"]
        else Playbook::KitFacts::SYSTEMS
        end
      end

      # POSIX ERE for git grep, not Ruby: \s and (?:...) are silently unsupported there and
      # match nothing, so they are written longhand. Rails kits are called as
      # pb_rails("kit"), pb_rails("kit/sub_template"), or pb_rails("pb_kit"); React kits
      # as the camelized tag.
      def usage(kit, system)
        pattern =
          if system == "rails"
            %Q{pb_rails\\([[:space:]]*["'](pb_)?#{kit}["'/]}
          else
            %Q{<#{camelize(kit)}[[:space:]/>]}
          end

        found = git_grep(pattern)
        found&.sort
      end

      # nil, not [], when the search could not run: "no matches" tells a tester there is
      # nothing to open, which a failed search cannot license.
      def git_grep(pattern)
        stdout, stderr, status = Open3.capture3(
          "git", "grep", "--no-color", "-l", "-E", pattern, "--", *SEARCHED_EXTENSIONS,
          chdir: @workspace
        )
        # git grep exits 1 for no matches, which is not an error.
        unless [0, 1].include?(status.exitstatus)
          record_failure("git grep exited #{status.exitstatus}: #{CommandOutput.utf8(stderr)}")
          return nil
        end

        CommandOutput.utf8(stdout).lines.map(&:chomp).reject(&:empty?)
      rescue => e
        record_failure("git grep could not be run: #{e.class}: #{e.message}")
        nil
      end

      # Annotated on the run, not carried into the report: git's stderr quotes paths out
      # of the workspace, and the agent reads the report as evidence.
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
