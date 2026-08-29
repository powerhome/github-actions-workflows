require_relative "../../spec_helper"
require "test_plan/dependency_delta"

require "rubygems/package"
require "tmpdir"
require "zlib"

RSpec.describe TestPlan::DependencyDelta::SafeTarExtractor do
  def build_tar_gz(path, entry_name)
    Zlib::GzipWriter.open(path) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        tar.add_file_simple(entry_name, 0o644, 4) { |file| file.write("test") }
      end
    end
  end

  it "extracts regular files" do
    Dir.mktmpdir do |directory|
      archive = File.join(directory, "safe.tgz")
      target = File.join(directory, "target")
      build_tar_gz(archive, "package/lib/example.rb")

      described_class.new.extract_gzip(archive, target)
      expect(File.read(File.join(target, "package/lib/example.rb"))).to eq("test")
    end
  end

  it "extracts archives that open with a pax global header" do
    Dir.mktmpdir do |directory|
      archive = File.join(directory, "codeload.tgz")
      target = File.join(directory, "target")
      payload = "52 comment=0000000000000000000000000000000000000000\n"

      Zlib::GzipWriter.open(archive) do |gzip|
        header = Gem::Package::TarHeader.new(
          name: "pax_global_header", mode: 0o644, size: payload.bytesize,
          prefix: "", typeflag: "g", mtime: 0, uid: 0, gid: 0
        )
        gzip.write(header.to_s)
        gzip.write(payload)
        gzip.write("\0" * (512 - (payload.bytesize % 512)))
        Gem::Package::TarWriter.new(gzip) do |tar|
          tar.add_file_simple("widget-abc123/lib/example.rb", 0o644, 4) { |file| file.write("test") }
        end
      end

      described_class.new.extract_gzip(archive, target)
      expect(File.read(File.join(target, "widget-abc123/lib/example.rb"))).to eq("test")
    end
  end

  it "rejects symlink entries" do
    Dir.mktmpdir do |directory|
      archive = File.join(directory, "symlink.tgz")
      Zlib::GzipWriter.open(archive) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          tar.add_symlink("package/escape", "/etc/passwd", 0o777)
        end
      end

      expect do
        described_class.new.extract_gzip(archive, File.join(directory, "target"))
      end.to raise_error(RuntimeError, /unsupported link or device entry/)
    end
  end

  it "rejects an archive that expands past the size limit" do
    stub_const("#{described_class}::MAX_EXTRACTED_BYTES", 512)

    Dir.mktmpdir do |directory|
      archive = File.join(directory, "bomb.tgz")
      Zlib::GzipWriter.open(archive) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          tar.add_file_simple("package/big.bin", 0o644, 1024) { |file| file.write("z" * 1024) }
        end
      end

      expect do
        described_class.new.extract_gzip(archive, File.join(directory, "target"))
      end.to raise_error(RuntimeError, /expands beyond/)
    end
  end

  it "rejects an archive with more files than the limit" do
    stub_const("#{described_class}::MAX_FILES", 2)

    Dir.mktmpdir do |directory|
      archive = File.join(directory, "many.tgz")
      Zlib::GzipWriter.open(archive) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          3.times { |index| tar.add_file_simple("package/#{index}.txt", 0o644, 1) { |f| f.write("x") } }
        end
      end

      expect do
        described_class.new.extract_gzip(archive, File.join(directory, "target"))
      end.to raise_error(RuntimeError, /more than 2 entries/)
    end
  end

  it "counts directory and metadata entries against the limit too" do
    stub_const("#{described_class}::MAX_FILES", 3)

    Dir.mktmpdir do |directory|
      archive = File.join(directory, "dirs.tgz")
      payload = "52 comment=0000000000000000000000000000000000000000\n"
      Zlib::GzipWriter.open(archive) do |gzip|
        header = Gem::Package::TarHeader.new(
          name: "pax_global_header", mode: 0o644, size: payload.bytesize,
          prefix: "", typeflag: "g", mtime: 0, uid: 0, gid: 0
        )
        gzip.write(header.to_s)
        gzip.write(payload)
        gzip.write("\0" * (512 - (payload.bytesize % 512)))
        Gem::Package::TarWriter.new(gzip) do |tar|
          5.times { |index| tar.mkdir("package/dir_#{index}", 0o755) }
        end
      end

      # An archive of nothing but directories and metadata used to bypass the cap
      # entirely, since only regular files were counted.
      expect do
        described_class.new.extract_gzip(archive, File.join(directory, "target"))
      end.to raise_error(RuntimeError, /more than 3 entries/)
    end
  end

  it "rejects path traversal" do
    Dir.mktmpdir do |directory|
      archive = File.join(directory, "unsafe.tgz")
      build_tar_gz(archive, "../escape.txt")

      expect do
        described_class.new.extract_gzip(archive, File.join(directory, "target"))
      end.to raise_error(RuntimeError, /Unsafe archive path/)
    end
  end
end
