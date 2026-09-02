# Flags bare self-calls that no `def` anywhere in the plugin defines.
#
# `ruby -c` parses such a file happily, and the stubbed load test never
# reaches these code paths, so a call site whose method was never added
# (progress_payload) shipped undetected and only failed at runtime.
BASE = File.expand_path('..', __dir__)
ALL  = (Dir.glob(File.join(BASE, 'kaitoi_sketchup', '**', '*.rb')) +
        [File.join(BASE, 'kaitoi_sketchup.rb')]).sort

# Come from Ruby, SketchUp, or mixins rather than from our own files.
KNOWN = %w[
  require require_relative puts print raise loop sleep rand format sprintf
  lambda proc block_given? catch throw binding freeze dup clone new send
  respond_to? instance_variable_get instance_variable_set define_method
  attr_accessor attr_reader attr_writer module_function private
  private_constant extend include prepend
  push pop shift unshift map select reject find detect each reduce inject
  join split strip chomp sub gsub match to_s to_i to_f to_a to_h to_json
  key? keys values merge length empty? first last reverse compact flatten
  min max sort sort_by max_by min_by group_by count sum uniq include?
  start_with? end_with? nil? is_a? kind_of? class tap
  file_loaded file_loaded? load
  super yield return next break defined?
].freeze

def defs_in(src)
  src.scan(/^\s*def\s+(?:self\.)?([a-z_][a-zA-Z0-9_]*[?!]?)/).flatten
end

# A comment mentioning int() or a regex containing text( is not a call.
def strip_noise(raw)
  raw.gsub(/^\s*#.*$/, '')
     .gsub(/"(?:[^"\\]|\\.)*"/, '""')
     .gsub(/'(?:[^'\\]|\\.)*'/, "''")
     .gsub(/%r\{[^}]*\}/, 'RX')
     .gsub(%r{/(?:[^/\\\n]|\\.)+/[imx]*}, 'RX')
end

all_defs = {}
ALL.each { |f| all_defs[f] = defs_in(File.read(f, encoding: 'UTF-8')) }
defined_anywhere = all_defs.values.flatten.uniq

failures = []
ALL.each do |path|
  raw   = File.read(path, encoding: 'UTF-8')
  src   = strip_noise(raw)
  calls = src.scan(/(?<![.:@$\w])([a-z_][a-zA-Z0-9_]*)\(/).flatten.uniq

  calls.each do |c|
    next if KNOWN.include?(c) || defined_anywhere.include?(c)
    failures << "#{path.sub(BASE + '/', '')}: calls #{c}(...) but nothing defines it"
  end
end

if failures.empty?
  puts "self-calls: all resolved (#{ALL.length} files, #{defined_anywhere.length} methods)"
  exit 0
end
failures.each { |f| puts "  #{f}" }
puts "\n#{failures.length} unresolved self-call(s)"
exit 1
