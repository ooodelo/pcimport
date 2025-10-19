# frozen_string_literal: true

require 'time'

module PointCloudPlugin
  module Core
    # Collects timing and point statistics for import stages.
    class PerformanceLogger
      def initialize(clock: nil, timestamp_provider: nil)
        @clock = clock || method(:default_clock)
        @timestamp_provider = timestamp_provider || method(:default_timestamp)
        reset!
      end

      def reset!
        @stages = {}
        @metadata = {}
        @start_clock = nil
        @end_clock = nil
        @started_at = nil
        @finished_at = nil
        @total_points = 0
      end

      def start_stage(stage, metadata = nil)
        stage = normalize_stage(stage)
        return unless stage

        now_clock = current_clock
        now_time = current_timestamp

        @start_clock ||= now_clock
        @started_at ||= now_time

        entry = stage_entry(stage)
        if entry[:active]
          finish_stage(stage)
          entry = stage_entry(stage)
        end

        entry[:active] = true
        entry[:current_clock] = now_clock
        entry[:current_wall] = now_time

        segment = { 'started_at' => iso(now_time) }
        merge_segment_metadata(segment, metadata)
        entry[:segments] << segment

        segment
      end

      def finish_stage(stage, metadata = nil)
        stage = normalize_stage(stage)
        return unless stage

        entry = stage_entry(stage)
        return unless entry[:active]

        now_clock = current_clock
        now_time = current_timestamp

        started_clock = entry[:current_clock]
        duration = started_clock ? now_clock - started_clock : 0.0
        duration = 0.0 if duration.nil? || duration.negative?

        entry[:total_duration] += duration

        segment = entry[:segments].last || {}
        segment = deep_dup(segment)
        segment['finished_at'] = iso(now_time)
        segment['duration'] = (segment['duration'] || 0.0) + duration
        merge_segment_metadata(segment, metadata)
        entry[:segments][-1] = segment

        entry[:active] = false
        entry[:current_clock] = nil
        entry[:current_wall] = nil

        @end_clock = now_clock
        @finished_at = now_time

        duration
      end

      def record_points(stage, count)
        stage = normalize_stage(stage)
        return unless stage

        points = begin
          Integer(count)
        rescue ArgumentError, TypeError
          nil
        end

        return unless points && points.positive?

        entry = stage_entry(stage)
        entry[:points] += points

        if (segment = entry[:segments].last)
          segment_points = Integer(segment['points']) rescue 0
          segment['points'] = segment_points + points
        end

        @total_points += points
        points
      end

      def total_points
        @total_points
      end

      def merge_metadata(hash)
        return unless hash.is_a?(Hash)

        hash.each do |key, value|
          set_metadata(key, value)
        end
      end

      def set_metadata(key, value)
        return if key.nil?

        @metadata[key.to_s] = value
      end

      def metadata
        deep_dup(@metadata)
      end

      def summary
        now_clock = @end_clock || (@start_clock ? current_clock : nil)
        now_time = @finished_at || (@started_at ? current_timestamp : nil)

        stages_snapshot = @stages.each_with_object({}) do |(stage, entry), memo|
          memo[stage.to_s] = stage_snapshot(entry, now_clock, now_time)
        end

        total_duration = compute_total_duration(now_clock)
        generated_time = now_time || current_timestamp

        summary = {
          'started_at' => iso(@started_at),
          'finished_at' => iso(now_time),
          'generated_at' => iso(generated_time),
          'total' => total_duration,
          'total_duration' => total_duration,
          'total_points' => @total_points,
          'stages' => stages_snapshot,
          'metadata' => metadata
        }

        if @metadata.key?('cache_hit')
          summary['cache_hit'] = !!@metadata['cache_hit']
        end

        if @metadata.key?('status')
          summary['status'] = @metadata['status'].to_s
        end

        summary
      end

      private

      def stage_snapshot(entry, now_clock, now_time)
        total = entry[:total_duration]
        segments = entry[:segments].map { |segment| deep_dup(segment) }

        if entry[:active] && entry[:current_clock]
          extra = now_clock && entry[:current_clock] ? now_clock - entry[:current_clock] : 0.0
          extra = 0.0 if extra.nil? || extra.negative?
          total += extra

          last_segment = segments.last || {}
          last_segment = deep_dup(last_segment)
          last_segment['duration'] = (last_segment['duration'] || 0.0) + extra
          last_segment['finished_at'] ||= iso(now_time)
          segments[-1] = last_segment
        end

        {
          'duration' => total,
          'points' => entry[:points],
          'segments' => segments
        }
      end

      def compute_total_duration(now_clock)
        return 0.0 unless @start_clock

        end_clock = now_clock || @end_clock || @start_clock
        duration = end_clock - @start_clock
        duration = 0.0 if duration.nil? || duration.negative?
        duration
      end

      def stage_entry(stage)
        @stages[stage] ||= {
          total_duration: 0.0,
          points: 0,
          segments: [],
          active: false,
          current_clock: nil,
          current_wall: nil
        }
      end

      def normalize_stage(stage)
        case stage
        when Symbol then stage
        when String then stage.to_sym
        else
          nil
        end
      end

      def merge_segment_metadata(segment, metadata)
        return unless metadata.is_a?(Hash)

        segment['metadata'] ||= {}
        metadata.each do |key, value|
          segment['metadata'][key.to_s] = value
        end
      end

      def current_clock
        @clock.call
      end

      def current_timestamp
        @timestamp_provider.call
      end

      def iso(time)
        return nil unless time

        if time.respond_to?(:iso8601)
          time.iso8601
        elsif time.is_a?(Numeric)
          Time.at(time).utc.iso8601
        else
          Time.parse(time.to_s).utc.iso8601
        end
      rescue StandardError
        time.to_s
      end

      def deep_dup(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, val), memo|
            memo[key] = deep_dup(val)
          end
        when Array
          value.map { |item| deep_dup(item) }
        else
          value
        end
      end

      def default_clock
        if Process.const_defined?(:CLOCK_MONOTONIC)
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        else
          Process.clock_gettime(:monotonic)
        end
      rescue Errno::EINVAL
        Time.now.to_f
      end

      def default_timestamp
        Time.now.utc
      end
    end
  end
end

