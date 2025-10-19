#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'pathname'
require 'coverage'
require 'minitest/autorun'

REPORT_PATH = File.expand_path('coverage.json', __dir__)

Coverage.start(lines: true)

test_files = Dir[File.expand_path('../pointcloud_plugin/test/**/*_test.rb', __dir__)]
test_files.sort.each { |file| require file }

Minitest.after_run do
  coverage_result = Coverage.result

  root = Pathname.new(File.expand_path('..', __dir__))

  summary = coverage_result.transform_keys do |path|
    Pathname.new(path).relative_path_from(root).to_s
  rescue ArgumentError
    path
  end

  totals = summary.each_with_object({ lines: 0, covered: 0 }) do |(_, data), acc|
    next unless data.is_a?(Hash)

    lines = Array(data[:lines])
    acc[:lines] += lines.count { |line| !line.nil? }
    acc[:covered] += lines.count { |line| line.to_i.positive? }
  end

  result = {
    generated_at: Time.now.utc.iso8601,
    totals: totals.merge(coverage: totals[:lines].zero? ? 0.0 : (totals[:covered].to_f / totals[:lines] * 100).round(2)),
    files: summary
  }

  File.write(REPORT_PATH, JSON.pretty_generate(result))
  warn "Coverage report written to #{REPORT_PATH}"
end
