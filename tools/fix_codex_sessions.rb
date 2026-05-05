#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "fileutils"

options = {
  codex_root: File.expand_path("~/.codex"),
  target_provider: "openai",
  write: false,
  backup: true
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/fix_codex_sessions.rb [options]"

  opts.on("--codex-root PATH", "Codex data root (default: ~/.codex)") do |path|
    options[:codex_root] = File.expand_path(path)
  end

  opts.on("--target-provider ID", "Provider id to write (default: openai)") do |id|
    options[:target_provider] = id
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
end.parse!

sessions_root = File.join(options[:codex_root], "sessions")
index_path = File.join(options[:codex_root], "session_index.jsonl")

unless Dir.exist?(sessions_root)
  warn "Sessions root does not exist: #{sessions_root}"
  exit 1
end

def parse_json_line(line, file)
  JSON.parse(line)
rescue JSON::ParserError => e
  raise "#{file}: invalid JSONL line: #{e.message}"
end

def backup_once(path)
  backup_path = "#{path}.bak"
  FileUtils.cp(path, backup_path) if File.exist?(path) && !File.exist?(backup_path)
end

def first_meaningful_user_message(events)
  events.each do |entry|
    next unless entry["type"] == "event_msg"
    next unless entry.dig("payload", "type") == "user_message"

    message = entry.dig("payload", "message").to_s.strip
    next if message.empty?
    next if message.start_with?("<environment_context>")

    return message
  end

  nil
end

def title_from_session(file, meta_payload, events)
  updated_name = nil

  events.each do |entry|
    next unless entry["type"] == "event_msg"
    next unless entry.dig("payload", "type") == "thread_name_updated"

    name = entry.dig("payload", "thread_name").to_s.strip
    updated_name = name unless name.empty?
  end

  title = updated_name || first_meaningful_user_message(events)
  title ||= File.basename(meta_payload["cwd"].to_s)
  title ||= File.basename(file, ".jsonl")
  title = title.gsub(/\s+/, " ").strip
  title.empty? ? "Untitled" : title[0, 80]
end

def updated_at_from_session(events, meta_payload)
  events.reverse_each do |entry|
    timestamp = entry["timestamp"].to_s
    return timestamp unless timestamp.empty?
  end

  meta_payload["timestamp"]
end

def user_visible_session?(meta_payload)
  !meta_payload["source"].is_a?(Hash)
end

session_files = Dir.glob(File.join(sessions_root, "**", "*.jsonl")).sort
provider_counts = Hash.new(0)
provider_changes = []
sessions = []

session_files.each do |file|
  lines = File.readlines(file, mode: "r:UTF-8")
  next if lines.empty?

  first = parse_json_line(lines.first, file)
  payload = first["payload"] || {}
  provider = payload["model_provider"]
  provider_counts[provider || "(missing)"] += 1

  events = lines.map { |line| parse_json_line(line, file) }
  sessions << {
    file: file,
    id: payload["id"],
    meta: first,
    payload: payload,
    events: events,
    title: title_from_session(file, payload, events),
    updated_at: updated_at_from_session(events, payload)
  }

  next if provider == options[:target_provider]
  next unless first["type"] == "session_meta" && provider

  provider_changes << [file, provider]

  next unless options[:write]

  backup_once(file) if options[:backup]
  first["payload"]["model_provider"] = options[:target_provider]
  lines[0] = "#{JSON.generate(first)}\n"
  File.write(file, lines.join, mode: "w:UTF-8")
end

index_entries = []
if File.exist?(index_path)
  File.foreach(index_path) do |line|
    next if line.strip.empty?

    index_entries << JSON.parse(line)
  end
end

indexed_ids = index_entries.map { |entry| entry["id"] }
missing_index_sessions = sessions.select do |session|
  session[:id] &&
    user_visible_session?(session[:payload]) &&
    !indexed_ids.include?(session[:id])
end
new_index_entries = missing_index_sessions.map do |session|
  {
    "id" => session[:id],
    "thread_name" => session[:title],
    "updated_at" => session[:updated_at]
  }
end

if options[:write] && new_index_entries.any?
  backup_once(index_path) if options[:backup]
  File.open(index_path, "a:UTF-8") do |file|
    new_index_entries.each do |entry|
      file.write("#{JSON.generate(entry)}\n")
    end
  end
end

puts "Scanned #{session_files.length} live session files under #{sessions_root}"
puts "Provider counts before normalization:"
provider_counts.sort_by { |provider, _count| provider.to_s }.each do |provider, count|
  puts "  #{provider}: #{count}"
end
puts
puts "#{options[:write] ? "Updated" : "Would update"} #{provider_changes.length} session files to model_provider=#{options[:target_provider].inspect}"
provider_changes.each do |file, provider|
  puts "  #{provider} -> #{options[:target_provider]}  #{file}"
end
puts
puts "#{options[:write] ? "Added" : "Would add"} #{new_index_entries.length} missing session_index entries"
new_index_entries.each do |entry|
  puts "  #{entry["updated_at"]}  #{entry["id"]}  #{entry["thread_name"]}"
end
