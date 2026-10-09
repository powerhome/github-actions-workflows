#!/usr/bin/env ruby
# frozen_string_literal: true

require "set"

# The lines a unified diff adds or changes, by path, numbered on the new side.
module DiffLines
  HUNK_HEADER = /\A@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/

module_function

  def added(diff)
    lines = {}
    path = nil
    line = nil

    diff.to_s.each_line do |raw|
      text = raw.chomp

      if text.start_with?("diff --git ")
        path = nil
        line = nil
      elsif line.nil? && text.start_with?("+++ ")
        path = new_path(text.delete_prefix("+++ "))
      elsif (match = HUNK_HEADER.match(text))
        line = Integer(match[1])
      elsif line && path
        case text[0]
        when "+"
          (lines[path] ||= Set.new) << line
          line += 1
        when " ", nil
          line += 1
        end
      end
    end

    lines
  end

  ESCAPES = { "a" => "\a", "b" => "\b", "t" => "\t", "n" => "\n", "v" => "\v", "f" => "\f", "r" => "\r" }.freeze

  def new_path(target)
    return nil if target == "/dev/null"

    unquote(target).delete_prefix("b/")
  end

  # Under the default core.quotePath git wraps a path with unusual characters in quotes and
  # escapes it C-style, spelling each byte above ASCII as octal.
  def unquote(target)
    return target unless target.start_with?('"') && target.end_with?('"')

    target[1...-1].b.gsub(/\\([0-7]{3}|.)/n) do
      escape = Regexp.last_match(1)
      escape.length == 3 ? escape.to_i(8).chr : ESCAPES.fetch(escape, escape)
    end.force_encoding(Encoding::UTF_8)
  end

  # Lines both diffs add: in an incremental review, what was pushed since the last review
  # that is also part of the pull request, which leaves out changes merged in from the base.
  def intersect(left, right)
    left.each_with_object({}) do |(path, lines), shared|
      common = lines & right.fetch(path, Set.new)
      shared[path] = common unless common.empty?
    end
  end
end
