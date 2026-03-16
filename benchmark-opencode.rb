#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require 'open3'
require 'timeout'
require 'shellwords'

BASE_DIR = File.expand_path(__dir__)
WORK_DIR = File.join(BASE_DIR, 'generated')
RESULTS_DIR = File.join(BASE_DIR, 'results')
LOGS_DIR    = File.join(BASE_DIR, 'logs')

GO_DIR = File.join(Dir.home, '.local', 'go')
NPM_PREFIX = File.join(Dir.home, '.local', 'npm')

LANGUAGES = {
  'ruby' => { exts: %w[rb], version_cmd: 'ruby --version' },
}

TRIALS = 3

# Opencode models (bailian-coding-plan)
OPENCODE_MODELS = {
  'glm-4.7' => 'bailian-coding-plan/glm-4.7',
  'glm-5' => 'bailian-coding-plan/glm-5',
  'kimi-k2.5' => 'bailian-coding-plan/kimi-k2.5',
  'MiniMax-M2.5' => 'bailian-coding-plan/MiniMax-M2.5',
  'qwen3-coder-next' => 'bailian-coding-plan/qwen3-coder-next',
  'qwen3-coder-plus' => 'bailian-coding-plan/qwen3-coder-plus',
  'qwen3-max' => 'bailian-coding-plan/qwen3-max-2026-01-23',
  'qwen3.5-plus' => 'bailian-coding-plan/qwen3.5-plus',
}

# ---------------------------------------------------------------------------
# CLI args
# ---------------------------------------------------------------------------

selected_languages = nil
selected_trials = TRIALS
selected_start = 1
selected_model = nil
dry_run = false

i = 0
while i < ARGV.length
  case ARGV[i]
  when '--lang', '-l'
    selected_languages = ARGV[i + 1].split(',').map(&:strip)
    i += 2
  when '--trials', '-t'
    selected_trials = ARGV[i + 1].to_i
    i += 2
  when '--start', '-s'
    selected_start = ARGV[i + 1].to_i
    i += 2
  when '--dry-run'
    dry_run = true
    i += 1
  when '--model', '-m'
    selected_model = ARGV[i + 1]
    i += 2
  else
    i += 1
  end
end

languages_to_run = selected_languages || LANGUAGES.keys

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def run_cmd(cmd, dir: nil, timeout: 600)
  opts = {}
  opts[:chdir] = dir if dir
  stdin_r, stdout_r, stderr_r, wait_thr = Open3.popen3(cmd, **opts)
  stdin_r.close
  stdout_r.set_encoding('UTF-8')
  stderr_r.set_encoding('UTF-8')
  stdout = stderr = ''
  begin
    Timeout.timeout(timeout) do
      stdout = stdout_r.read
      stderr = stderr_r.read
    end
  rescue Timeout::Error
    Process.kill('TERM', wait_thr.pid) rescue nil
    stdout = stdout_r.read rescue ''
    stderr = "Timeout after #{timeout}s"
  end
  stdout_r.close
  stderr_r.close
  status = wait_thr.value
  { stdout: stdout, stderr: stderr, exit_code: status.exitstatus, success: status.success? }
end

def extra_path
  "#{GO_DIR}/bin:#{NPM_PREFIX}/bin"
end

def get_version(lang)
  config = LANGUAGES[lang]
  cmd = "export PATH=#{extra_path}:$PATH && #{config[:version_cmd]}"
  result = run_cmd(cmd)
  if result[:success]
    (result[:stdout].strip.empty? ? result[:stderr].strip : result[:stdout].strip).lines.first&.strip || 'unknown'
  else
    'not installed'
  end
end

def count_loc(dir, lang)
  config = LANGUAGES[lang]
  exts = config[:exts]
  files = exts.flat_map { |e| Dir.glob(File.join(dir, '**', "*.#{e}")) }
  files.reject! { |f| f.include?('/node_modules/') || f.include?('/target/') }

  minigit = File.join(dir, 'minigit')
  if File.exist?(minigit) && !files.include?(minigit)
    begin
      content = File.read(minigit, encoding: 'UTF-8')
      files << minigit if content.valid_encoding?
    rescue StandardError
    end
  end

  files.sum do |f|
    begin
      File.readlines(f).count { |l| !l.strip.empty? }
    rescue StandardError
      0
    end
  end
end

def parse_opencode_output(raw_output)
  raw_output = raw_output.dup.force_encoding('UTF-8')
  return nil if raw_output.strip.empty?

  # Opencode outputs JSON events (one per line)
  # Tokens/cost are in step_finish events under part.tokens and part.cost
  lines = raw_output.lines.map(&:strip).reject(&:empty?)

  total_input = 0
  total_output = 0
  total_cache_read = 0
  total_cache_write = 0
  total_cost = 0.0
  num_steps = 0

  lines.each do |line|
    begin
      event = JSON.parse(line)
      next unless event.is_a?(Hash) && event['type'] == 'step_finish'

      part = event['part'] || {}
      tokens = part['tokens'] || {}

      total_input += tokens['input'] || 0
      total_output += tokens['output'] || 0
      total_cache_read += tokens.dig('cache', 'read') || 0
      total_cache_write += tokens.dig('cache', 'write') || 0
      total_cost += part['cost'] || 0
      num_steps += 1
    rescue JSON::ParserError
      next
    end
  end

  return nil if num_steps == 0

  {
    input_tokens: total_input,
    output_tokens: total_output,
    cache_creation_tokens: total_cache_write,
    cache_read_tokens: total_cache_read,
    cost_usd: total_cost,
    num_turns: num_steps,
    duration_ms: 0,
  }
rescue JSON::ParserError => e
  puts "  WARNING: Failed to parse Opencode JSON output: #{e.message}"
  nil
end

def run_opencode(prompt, dir:, model:, log_path: nil)
  model_id = OPENCODE_MODELS[model] || model
  cmd = "opencode run -m #{Shellwords.escape(model_id)} --format json -- #{Shellwords.escape(prompt)}"

  puts "  Command: #{cmd}"
  puts "  Running Opencode..."
  start_time = Time.now
  result = run_cmd(cmd, dir: dir, timeout: 1200)
  elapsed = Time.now - start_time

  if log_path
    FileUtils.mkdir_p(File.dirname(log_path))
    File.write(log_path, result[:stdout])
    puts "  Log saved to #{log_path}"
  end

  {
    stdout: result[:stdout],
    stderr: result[:stderr],
    success: result[:success],
    elapsed_seconds: elapsed.round(1),
    opencode_data: parse_opencode_output(result[:stdout]),
  }
end

def run_tests(test_script, dir:)
  cmd = "export PATH=#{extra_path}:$PATH && bash #{test_script}"
  result = run_cmd(cmd, dir: dir, timeout: 120)

  output = result[:stdout] + result[:stderr]
  passed = output[/PASSED:\s*(\d+)/, 1]&.to_i || 0
  failed = output[/FAILED:\s*(\d+)/, 1]&.to_i || 0

  {
    success: result[:success],
    passed: passed,
    failed: failed,
    total: passed + failed,
    output: output,
  }
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

puts '=' * 60
puts 'Opencode Language Benchmark'
puts '=' * 60
puts

opencode_version_result = run_cmd('opencode --version 2>/dev/null || echo unknown')
opencode_version = opencode_version_result[:stdout].strip

puts "Opencode Version: #{opencode_version}"
puts "Languages: #{languages_to_run.join(', ')}"
puts "Trials: #{selected_start}..#{selected_start + selected_trials - 1} (#{selected_trials} trials)"
puts "Dry run: #{dry_run}"

if selected_model
  model_id = OPENCODE_MODELS[selected_model] || selected_model
  puts "Model: #{selected_model} (#{model_id})"
end
puts

# Language versions
puts '--- Language Versions ---'
versions = {}
languages_to_run.each do |lang|
  versions[lang] = get_version(lang)
  puts "  #{lang}: #{versions[lang]}"
end
puts

# Ensure directories exist
FileUtils.mkdir_p(WORK_DIR)
FileUtils.mkdir_p(RESULTS_DIR)

# Warmup
unless dry_run
  puts '--- Warmup ---'
  warmup_dir = File.join(WORK_DIR, '.warmup')
  FileUtils.mkdir_p(warmup_dir)
  warmup_result = run_opencode('Respond with just the word OK.', dir: warmup_dir, model: selected_model)
  puts "  Warmup done in #{warmup_result[:elapsed_seconds]}s (success=#{warmup_result[:success]})"
  FileUtils.rm_rf(warmup_dir)
  puts
end

results = []

selected_trials.times do |trial_idx|
  trial = selected_start + trial_idx
  languages_to_run.each do |lang|
    puts '=' * 60
    puts "Trial #{trial} (#{trial_idx + 1}/#{selected_trials}) - #{lang}"
    puts '=' * 60

    dir_name = lang.tr('/', '-')
    v1_dir = File.join(WORK_DIR, "minigit-#{dir_name}-#{trial}-v1")
    v2_dir = File.join(WORK_DIR, "minigit-#{dir_name}-#{trial}-v2")
    FileUtils.rm_rf(v1_dir)
    FileUtils.rm_rf(v2_dir)
    FileUtils.mkdir_p(v1_dir)

    record = {
      runner: 'opencode',
      model: selected_model,
      language: lang, trial: trial, v1_dir: v1_dir, v2_dir: v2_dir,
      v1_time: nil, v1_pass: false, v1_passed_count: 0, v1_failed_count: 0, v1_total_count: 0, v1_loc: 0,
      v2_time: nil, v2_pass: false, v2_passed_count: 0, v2_failed_count: 0, v2_total_count: 0, v2_loc: 0,
      v1_opencode: nil, v2_opencode: nil,
    }

    # --- Phase 1: v1 ---
    puts "\n--- Phase 1: v1 ---"
    FileUtils.cp(File.join(BASE_DIR, 'SPEC-v1.txt'), v1_dir)
    FileUtils.cp(File.join(BASE_DIR, 'test-v1.sh'), v1_dir)

    v1_prompt = "Implement minigit as described in SPEC-v1.txt using #{lang.capitalize}. " \
                "The executable must be named 'minigit' and be runnable as ./minigit. " \
                "For compiled languages, include a Makefile or build script. " \
                "For interpreted languages, ensure the minigit file has a proper shebang line and is executable. " \
                "Verify your implementation passes all tests by running: bash test-v1.sh"

    if dry_run
      puts "  [DRY RUN] Would run Opencode with prompt for v1 #{lang}"
      record[:v1_time] = 0
    else
      v1_log = File.join(LOGS_DIR, "opencode-minigit-#{dir_name}-#{trial}-v1.json")
      v1_result = run_opencode(v1_prompt, dir: v1_dir, model: selected_model, log_path: v1_log)
      record[:v1_time] = v1_result[:elapsed_seconds]
      record[:v1_opencode] = v1_result[:opencode_data]
      puts "  Opencode finished in #{v1_result[:elapsed_seconds]}s (success=#{v1_result[:success]})"

      puts '  Running v1 tests...'
      test_result = run_tests('test-v1.sh', dir: v1_dir)
      record[:v1_pass] = test_result[:success]
      record[:v1_passed_count] = test_result[:passed]
      record[:v1_failed_count] = test_result[:failed]
      record[:v1_total_count] = test_result[:total]
      puts "  Tests: #{test_result[:passed]}/#{test_result[:total]} passed (#{test_result[:success] ? 'PASS' : 'FAIL'})"

      record[:v1_loc] = count_loc(v1_dir, lang)
      puts "  LOC: #{record[:v1_loc]}"
    end

    # --- Phase 2: v2 ---
    puts "\n--- Phase 2: v2 ---"
    FileUtils.cp_r(v1_dir, v2_dir)
    FileUtils.cp(File.join(BASE_DIR, 'SPEC-v2.txt'), v2_dir)
    FileUtils.cp(File.join(BASE_DIR, 'test-v2.sh'), v2_dir)

    v2_prompt = "Read SPEC-v2.txt and extend the existing minigit implementation " \
                "with checkout and reset commands. " \
                "Verify your implementation passes all tests by running: bash test-v2.sh"

    if dry_run
      puts "  [DRY RUN] Would run Opencode with prompt for v2 #{lang}"
      record[:v2_time] = 0
    else
      v2_log = File.join(LOGS_DIR, "opencode-minigit-#{dir_name}-#{trial}-v2.json")
      v2_result = run_opencode(v2_prompt, dir: v2_dir, model: selected_model, log_path: v2_log)
      record[:v2_time] = v2_result[:elapsed_seconds]
      record[:v2_opencode] = v2_result[:opencode_data]
      puts "  Opencode finished in #{v2_result[:elapsed_seconds]}s (success=#{v2_result[:success]})"

      puts '  Running v2 tests...'
      test_result = run_tests('test-v2.sh', dir: v2_dir)
      record[:v2_pass] = test_result[:success]
      record[:v2_passed_count] = test_result[:passed]
      record[:v2_failed_count] = test_result[:failed]
      record[:v2_total_count] = test_result[:total]
      puts "  Tests: #{test_result[:passed]}/#{test_result[:total]} passed (#{test_result[:success] ? 'PASS' : 'FAIL'})"

      record[:v2_loc] = count_loc(v2_dir, lang)
      puts "  LOC: #{record[:v2_loc]}"
    end

    results << record
    puts
  end
end

# ---------------------------------------------------------------------------
# Save results JSON
# ---------------------------------------------------------------------------

puts '=' * 60
puts 'Saving results...'
puts '=' * 60

# Save metadata alongside results
meta = {
  date: Time.now.strftime('%Y-%m-%d %H:%M:%S'),
  runner: 'opencode',
  model: selected_model,
  opencode_version: opencode_version,
  trials: selected_trials,
  versions: versions,
}

File.write(File.join(RESULTS_DIR, 'meta.json'), JSON.pretty_generate(meta))

# Load existing results and append new ones
results_path = File.join(RESULTS_DIR, 'results.json')
existing = if File.exist?(results_path)
             JSON.parse(File.read(results_path)) rescue []
           else
             []
           end
all_results = existing + results.map { |r| r.transform_keys(&:to_s) }
File.write(results_path, JSON.pretty_generate(all_results))

puts "Results saved to #{RESULTS_DIR}/"
puts 'Run `ruby report.rb` to generate the report.'