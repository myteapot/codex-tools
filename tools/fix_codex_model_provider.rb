#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "fileutils"

options = {
  root: File.expand_path("~/.codex/sessions"),
  target: "openai",
  write: false,
  backup: true
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/fix_codex_model_provider.rb [options]"

  opts.on("--root PATH", "Sessions root to scan (default: ~/.codex/sessions)") do |path|
    options[:root] = File.expand_path(path)
  end

  opts.on("--target ID", "Provider id to write (default: openai)") do |id|
    options[:target] = id
  end

  opts.on("--write", "Apply changes. Without this, only prints a dry run.") do
    options[:write] = true
  end

  opts.on("--no-backup", "Do not create .bak files when writing.") do
    options[:backup] = false
  end

  opts.on("-h", "--help", "Show this help.") do
    puts opts
    exit
  end
end

parser.parse!

unless Dir.exist?(options[:root])
  warn "Sessions root does not exist: #{options[:root]}"
  exit 1
end

files = Dir.glob(File.join(options[:root], "**", "*.jsonl")).sort
changed = []
unchanged = 0
skipped = []
seen = Hash.new(0)

files.each do |file|
  content = File.read(file, mode: "r:UTF-8")
  first_line, rest = content.split("\n", 2)

  if first_line.nil? || first_line.empty?
    skipped << [file, "empty file"]
    next
  end

  begin
    entry = JSON.parse(first_line)
  rescue JSON::ParserError => e
    skipped << [file, "invalid first-line JSON: #{e.message}"]
    next
  end

  provider = entry.dig("payload", "model_provider")
  seen[provider || "(missing)"] += 1

  unless entry["type"] == "session_meta" && provider
    skipped << [file, "first line is not session_meta with model_provider"]
    next
  end

  if provider == options[:target]
    unchanged += 1
    next
  end

  entry["payload"]["model_provider"] = options[:target]
  new_first_line = JSON.generate(entry)
  new_content = rest.nil? ? new_first_line : "#{new_first_line}\n#{rest}"
  changed << [file, provider]

  next unless options[:write]

  backup_path = "#{file}.bak"
  FileUtils.cp(file, backup_path) if options[:backup] && !File.exist?(backup_path)
  File.write(file, new_content, mode: "w:UTF-8")
end

puts "Scanned #{files.length} jsonl files under #{options[:root]}"
puts "Provider counts before normalization:"
seen.sort_by { |provider, _count| provider.to_s }.each do |provider, count|
  puts "  #{provider}: #{count}"
end
puts
puts "#{options[:write] ? "Updated" : "Would update"} #{changed.length} files to model_provider=#{options[:target].inspect}"

changed.each do |file, provider|
  puts "  #{provider} -> #{options[:target]}  #{file}"
end

puts
puts "Already correct: #{unchanged}"
puts "Skipped: #{skipped.length}"
skipped.each do |file, reason|
  puts "  #{file}: #{reason}"
end

exit 0
