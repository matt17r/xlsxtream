# frozen_string_literal: true
# Compares the performance of two versions of xlsxtream.
#
#   bundle exec ruby bench/compare.rb [BASE] [TARGET]
#
# BASE and TARGET are git refs. BASE defaults to master, TARGET defaults to
# the working tree (including uncommitted changes). Each ref's lib/ is
# extracted with git archive, and every measurement runs in a fresh Ruby
# process. Runs alternate between the two versions to even out drift.
#
# Environment variables:
#
#   SIZE=large             1,000,000 rows (close to Excel's per-sheet limit),
#                          3 rounds, 1 iteration, streaming only, to check that
#                          large sheets stay fast and memory stays flat
#                          (all scenarios take around 20 minutes)
#   SIZE=xl                10 sheets of 1,000,000 rows, 1 round, streaming
#                          only, mixed and strings_sst_unique by default
#                          (around an hour)
#   ROWS=20000             rows per worksheet
#   SHEETS=1               worksheets per run
#   ROUNDS=5               processes per version and scenario
#   ITERATIONS=3           timed runs per process (the fastest is kept)
#   LAYERS=xml,xlsx        xml: worksheet XML only, xlsx: zipped workbook
#   SOURCES=stream,memory  stream: rows built while writing, memory: rows
#                          built first and written from an array
#   SCENARIOS=mixed,...    defaults to all scenarios in bench/scenarios.rb
#   OPTIONS='{"x":true}'   JSON worksheet options added to every scenario,
#                          e.g. to measure the cost of turning on a new option
#
# Times and allocations exclude building the rows, which is measured
# separately in each process. Allocation counts are deterministic, so any
# change in "allocs/row" is real even when timings are noisy.
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'zip_kit'
require_relative 'scenarios'

ROOT = File.expand_path('..', __dir__)
BASE = ARGV[0] || 'master'
TARGET = ARGV[1]
SIZES = {
  'default' => { 'ROWS' => '20000', 'SHEETS' => '1', 'ROUNDS' => '5', 'ITERATIONS' => '3',
                 'SOURCES' => 'stream,memory' },
  'large' => { 'ROWS' => '1000000', 'SHEETS' => '1', 'ROUNDS' => '3', 'ITERATIONS' => '1',
               'SOURCES' => 'stream' },
  'xl' => { 'ROWS' => '1000000', 'SHEETS' => '10', 'ROUNDS' => '1', 'ITERATIONS' => '1',
            'SOURCES' => 'stream', 'SCENARIOS' => 'mixed,strings_sst_unique' }
}.freeze
SIZE = SIZES.fetch(ENV.fetch('SIZE', 'default')) { abort "SIZE must be one of #{SIZES.keys.join(', ')}" }
ROWS = Integer(ENV.fetch('ROWS', SIZE['ROWS']))
ROUNDS = Integer(ENV.fetch('ROUNDS', SIZE['ROUNDS']))
SHEETS = Integer(ENV.fetch('SHEETS', SIZE['SHEETS']))
ITERATIONS = Integer(ENV.fetch('ITERATIONS', SIZE['ITERATIONS']))
SOURCES = ENV.fetch('SOURCES', SIZE['SOURCES']).split(',')
LAYERS = ENV.fetch('LAYERS', 'xml,xlsx').split(',')
SCENARIOS = ENV.fetch('SCENARIOS') { SIZE['SCENARIOS'] || Bench::SCENARIOS.keys.join(',') }.split(',')
ZIP_KIT_PATHS = Gem.loaded_specs.fetch('zip_kit').full_require_paths
# The summary reports a time or RSS change when it's at least MIN_CHANGE % and
# larger than the noise, since a few rounds can understate the noise. With a
# single round there is no noise to compare against, so changes are reported
# with "noise n/a" for the reader to judge.
MIN_CHANGE = 2.0

def lib_for(ref, dir)
  return File.join(ROOT, 'lib') if ref.nil?

  target = File.join(dir, ref.gsub(/[^\w.-]/, '_'))
  FileUtils.mkdir_p(target)
  archive, status = Open3.capture2('git', '-C', ROOT, 'archive', ref, 'lib', :binmode => true)
  abort "git archive #{ref} failed" unless status.success?
  _, status = Open3.capture2('tar', '-x', '-C', target, :stdin_data => archive, :binmode => true)
  abort "Extracting #{ref} failed" unless status.success?
  File.join(target, 'lib')
end

def measure(lib, scenario, layer, source)
  load_path = ([lib] + ZIP_KIT_PATHS).flat_map { |path| ['-I', path] }
  command = [RbConfig.ruby, *load_path, File.join(__dir__, 'run.rb'),
             scenario, layer, source, ROWS.to_s, SHEETS.to_s, ITERATIONS.to_s]
  # Run without Bundler, which would put the working tree's lib/ (from the
  # gemspec) on the load path ahead of the version being measured.
  env = ENV.to_h.select { |key, _| !key.start_with?('BUNDLE', 'RUBYOPT', 'RUBYLIB') }
  output, status = Open3.capture2(env, *command, :unsetenv_others => true)
  abort "Benchmark run failed: #{command.join(' ')}" unless status.success?

  result = JSON.parse(output)
  unless File.realpath(result['loaded_from']).start_with?(File.realpath(lib))
    abort "Expected xlsxtream from #{lib}, but loaded #{result['loaded_from']}"
  end
  result
end

def median(values)
  sorted = values.sort
  middle = sorted.size / 2
  sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
end

def spread(values)
  (values.max - values.min) / median(values) * 100 if values.size > 1
end

def significant?(change, noise)
  change.abs > [noise || 0, MIN_CHANGE].max
end

def noise_label(noise)
  noise ? format('%.1f%%', noise) : 'n/a'
end

def summarize(heading, results, empty)
  puts format('  %-8s%s', heading, empty) if results.empty?
  results.each_with_index do |result, index|
    puts format('  %-8s%s  %s', index.zero? ? heading : '', result[:name], yield(result))
  end
end

Dir.mktmpdir('xlsxtream-bench') do |dir|
  libs = { :base => lib_for(BASE, dir), :target => lib_for(TARGET, dir) }
  target_name = TARGET || 'working tree'
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  puts "xlsxtream benchmark: #{BASE} (base) vs #{target_name} (target)"
  puts "Ruby #{RUBY_VERSION}, #{SHEETS} x #{ROWS} rows x #{Bench::COLUMNS} columns, " \
       "#{ROUNDS} rounds x #{ITERATIONS} iterations"
  puts "Extra options: #{ENV['OPTIONS']}" if ENV['OPTIONS']
  puts
  puts format('%-18s %-5s %-6s %9s | %9s %9s %7s %6s | %8s %8s | %7s %7s',
              '', '', '', 'rows', 'base', 'target', 'change', 'noise',
              'base', 'target', 'base', 'target')
  puts format('%-18s %-5s %-6s %9s | %9s %9s %7s %6s | %8s %8s | %7s %7s',
              'scenario', 'layer', 'source', 'ms', 'ms', 'ms', '', '',
              'allocs', 'allocs', 'RSS MB', 'RSS MB')

  results = []
  SCENARIOS.each do |scenario|
    LAYERS.product(SOURCES).each do |layer, source|
      times = { :base => [], :target => [] }
      generate_times = []
      allocations = {}
      rows = nil
      rss = { :base => [], :target => [] }

      ROUNDS.times do |round|
        order = round.even? ? [:base, :target] : [:target, :base]
        order.each do |version|
          result = measure(libs[version], scenario, layer, source)
          times[version] << result['times'].min - result['generate_times'].min
          generate_times << result['generate_times'].min
          allocations[version] = result['allocations'] - result['generate_allocations']
          rows = result['rows']
          rss[version] << result['rss'] / 1024.0
        end
      end

      base = median(times[:base])
      target = median(times[:target])
      noise = [spread(times[:base]), spread(times[:target])].compact.max
      change = (target - base) / base * 100
      rss_base = median(rss[:base])
      rss_target = median(rss[:target])
      name = format('%-18s %-5s %-6s', scenario, layer, source)
      results << { :name => name, :change => change, :noise => noise,
                   :allocations => allocations, :rows => rows,
                   :rss => { :base => rss_base, :target => rss_target },
                   :rss_change => (rss_target - rss_base) / rss_base * 100,
                   :rss_noise => [spread(rss[:base]), spread(rss[:target])].compact.max }
      puts format('%s %9.1f | %9.1f %9.1f %+6.1f%% %6s | %8.1f %8.1f | %7.0f %7.0f',
                  name, median(generate_times) * 1000,
                  base * 1000, target * 1000, change, noise_label(noise),
                  allocations[:base].fdiv(rows), allocations[:target].fdiv(rows),
                  rss_base, rss_target)
    end
  end

  puts
  puts 'rows: time spent building the rows while streaming, the same for both versions and excluded'
  puts '      from the rest (0 for the memory source, where rows are built before timing)'
  puts 'base/target ms: median time spent in xlsxtream'
  puts 'change: target vs base (negative is faster)'
  puts 'noise: largest spread (max - min) / median across rounds; ignore changes smaller than this'
  puts '       (n/a with a single round, when only large changes are meaningful)'
  puts 'allocs: objects allocated by xlsxtream per row (deterministic)'
  puts 'RSS MB: median resident memory at the end of a run across rounds (approximate, varies by a'
  puts '        few MB between identical runs; includes the rows themselves for the memory source)'

  changed = results.select { |result| significant?(result[:change], result[:noise]) }
  slower, faster = changed.partition { |result| result[:change] > 0 }
  allocs = results.reject { |result| result[:allocations][:base] == result[:allocations][:target] }
  memory = results.select { |result| significant?(result[:rss_change], result[:rss_noise]) }

  puts
  puts 'Summary'
  if changed.empty?
    puts "  Time:   no changes beyond noise in all #{results.size}"
  else
    [['Slower:', slower], ['Faster:', faster]].each do |heading, group|
      summarize(heading, group, 'none') do |result|
        format('%+.1f%% (noise %s)', result[:change], noise_label(result[:noise]))
      end
    end
  end
  summarize('Allocs:', allocs, "identical in all #{results.size}") do |result|
    base, target = result[:allocations].values_at(:base, :target)
    format('%+d objects in total (%.2f -> %.2f per row)',
           target - base, base.fdiv(result[:rows]), target.fdiv(result[:rows]))
  end
  summarize('Memory:', memory, "no changes beyond noise in all #{results.size}") do |result|
    format('%.0f -> %.0f MB (%+.1f%%, noise %s)', result[:rss][:base], result[:rss][:target],
           result[:rss_change], noise_label(result[:rss_noise]))
  end
  puts format('Finished in %.0fs', Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
end
