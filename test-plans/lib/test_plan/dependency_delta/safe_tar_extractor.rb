require "fileutils"
require "pathname"
require "rubygems/package"
require "tempfile"
require "zlib"
require_relative "./public_downloader"

module TestPlan
  module DependencyDelta
    class SafeTarExtractor
      MAX_EXTRACTED_BYTES = 100 * 1024 * 1024
      MAX_FILES = 20_000
      # pax extended headers carry metadata about the *next* entry, not content of their
      # own. GitHub's codeload tarballs open with a global one, so refusing them refuses
      # every Git dependency archive.
      PAX_HEADER_TYPEFLAGS = %w[g x].freeze

      def extract_gzip(path, destination)
        Zlib::GzipReader.open(path) do |gzip|
          Gem::Package::TarReader.new(gzip) { |tar| extract_entries(tar, destination) }
        end
      end

      def extract_gem(path, destination)
        Tempfile.create(["gem-data", ".tar.gz"]) do |data_archive|
          File.open(path, "rb") do |gem_file|
            Gem::Package::TarReader.new(gem_file) do |tar|
              entry = tar.find { |candidate| candidate.full_name == "data.tar.gz" }
              raise "Gem archive does not contain data.tar.gz" unless entry
              raise "Gem data archive exceeds 50 MiB" if entry.header.size > PublicDownloader::MAX_DOWNLOAD_BYTES

              data_archive.write(entry.read)
              data_archive.flush
            end
          end
          extract_gzip(data_archive.path, destination)
        end
      end

    private

      def extract_entries(tar, destination)
        total_bytes = 0
        entries = 0
        root = File.expand_path(destination)

        tar.each do |entry|
          # Counted before dispatching on type: an archive of nothing but directory or
          # metadata entries costs the same inodes and CPU as one full of files, and
          # counting only regular files let it past this limit entirely.
          entries += 1
          raise "Archive contains more than #{MAX_FILES} entries" if entries > MAX_FILES

          next if PAX_HEADER_TYPEFLAGS.include?(entry.header.typeflag)

          relative = safe_relative_path(entry.full_name)
          next if relative == "."

          target = File.expand_path(relative, root)
          raise "Archive entry escapes extraction root: #{entry.full_name}" unless target.start_with?("#{root}#{File::SEPARATOR}")

          if entry.directory?
            FileUtils.mkdir_p(target)
          elsif entry.file?
            total_bytes += entry.header.size
            raise "Archive expands beyond 100 MiB" if total_bytes > MAX_EXTRACTED_BYTES

            FileUtils.mkdir_p(File.dirname(target))
            File.open(target, "wb") { |file| IO.copy_stream(entry, file) }
          else
            raise "Archive contains unsupported link or device entry: #{entry.full_name}"
          end
        end
      end

      def safe_relative_path(value)
        path = Pathname.new(value)
        clean = path.cleanpath.to_s
        if path.absolute? || clean == ".." || clean.start_with?("../")
          raise "Unsafe archive path: #{value}"
        end

        clean
      end
    end
  end
end
