# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../../core/performance_logger'

module PointCloudPlugin
  module Core
    class PerformanceLoggerTest < Minitest::Test
      def setup
        @clock_value = 0.0
        @clock = lambda do
          @clock_value += 1.0
        end

        base_time = Time.utc(2024, 1, 1, 0, 0, 0)
        @timestamp = lambda do
          current = base_time
          base_time += 60
          current
        end
      end

      def test_summary_tracks_durations_points_and_metadata
        logger = PerformanceLogger.new(clock: @clock, timestamp_provider: @timestamp)

        logger.start_stage(:hash_check)
        logger.record_points(:hash_check, 5)
        logger.finish_stage(:hash_check)

        logger.start_stage(:cache_write)
        logger.record_points(:cache_write, 2)
        logger.finish_stage(:cache_write)

        logger.set_metadata('cache_hit', true)

        summary = logger.summary

        assert_in_delta 3.0, summary['total'], 1e-6
        assert_equal 7, summary['total_points']
        assert_equal true, summary['cache_hit']

        stages = summary['stages']
        assert_in_delta 1.0, stages['hash_check']['duration'], 1e-6
        assert_equal 5, stages['hash_check']['points']
        assert_in_delta 1.0, stages['cache_write']['duration'], 1e-6
        assert_equal 2, stages['cache_write']['points']

        assert_equal '2024-01-01T00:00:00Z', summary['started_at']
        assert_equal '2024-01-01T00:03:00Z', summary['finished_at']
      end

      def test_record_points_ignores_non_positive_values
        logger = PerformanceLogger.new(clock: @clock, timestamp_provider: @timestamp)

        logger.start_stage(:sampling)
        logger.record_points(:sampling, -5)
        logger.record_points(:sampling, 'invalid')
        logger.finish_stage(:sampling)

        summary = logger.summary
        assert_equal 0, summary['stages']['sampling']['points']
      end
    end
  end
end

