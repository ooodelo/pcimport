# frozen_string_literal: true

require 'securerandom'
require_relative '../core/chunk'
require_relative '../core/chunk_store'
require_relative '../core/lod/pipeline'
require_relative 'main_thread_queue'

module PointCloudPlugin
  module Bridge
    # Handles background import of point cloud files and forwards chunks to the core pipeline.
    class ImportJob
      attr_reader :path, :reader, :pipeline, :queue, :progress

      def initialize(path:, reader:, pipeline:, queue: MainThreadQueue.new)
        @path = path
        @reader = reader
        @pipeline = pipeline
        @queue = queue
        @progress = 0.0
        @chunk_index = 0
        @thread = nil
      end

      def start(&block)
        @on_complete = block
        @thread = Thread.new { run }
      end

      def join
        @thread&.join
      end

      private

      def run
        total_points = 0
        size_in_bytes = file_size_bytes
        estimated_total = estimate_total_points(size_in_bytes)
        first_chunk_shown = false
        @start_time = monotonic_time
        @last_log_time = @start_time
        @last_logged_percent = 0.0

        log_start(size_in_bytes, estimated_total)

        reader.each_batch do |batch|
          total_points += batch.size
          chunk = pack(batch)
          first_chunk = (@chunk_index.zero?)
          key = next_key
          pipeline.submit_chunk(key, chunk)
          @progress = total_points

          progress_percent = if estimated_total && estimated_total.positive?
                               [((total_points.to_f / estimated_total) * 100.0), 100.0].min
                             end

          elapsed = elapsed_time
          bytes_processed = processed_bytes(total_points, estimated_total, size_in_bytes)
          log_progress(total_points, estimated_total, progress_percent, elapsed, bytes_processed)

          queue.push do
            notify_progress(
              key,
              chunk,
              total_points: total_points,
              estimated_total: estimated_total,
              progress_percent: progress_percent,
              first_chunk: first_chunk
            )

            unless first_chunk_shown
              first_chunk_shown = true if first_chunk
              if first_chunk && defined?(PointCloudPlugin)
                PointCloudPlugin.activate_tool if PointCloudPlugin.respond_to?(:activate_tool)
                if PointCloudPlugin.respond_to?(:focus_camera_on_chunk)
                  PointCloudPlugin.focus_camera_on_chunk(chunk)
                end
              end
            end

            update_hud_progress(
              total_points,
              estimated_total,
              progress_percent,
              elapsed: elapsed,
              bytes_processed: bytes_processed
            )

            MainThreadQueue.post { Sketchup.active_model.active_view.invalidate }
          end
        end

        elapsed = elapsed_time
        log_completion(total_points, elapsed, size_in_bytes)

        queue.push do
          update_hud_progress(
            total_points,
            estimated_total,
            100.0,
            elapsed: elapsed,
            bytes_processed: size_in_bytes
          )
          @on_complete&.call(self)
        end
      rescue StandardError => e
        warn("Import failed: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
        queue.push do
          update_hud_failure(e)
          if defined?(UI) && UI.respond_to?(:messagebox)
            UI.messagebox("Point cloud import failed: #{e.message}")
          end
        end
      end

      def notify_progress(key, chunk, total_points: nil, estimated_total: nil, progress_percent: nil, first_chunk: false)
        # Hook for UI updates; by default does nothing but can be extended.
        if respond_to?(:on_chunk)
          begin
            on_chunk(
              key,
              chunk,
              total_points: total_points,
              estimated_total: estimated_total,
              progress_percent: progress_percent,
              first_chunk: first_chunk
            )
          rescue ArgumentError
            on_chunk(key, chunk)
          end
        end
      end

      def estimate_total_points(size_in_bytes = nil)
        size = size_in_bytes || file_size_bytes
        return unless size

        average_point_size = 32.0
        [(size / average_point_size).ceil, 1].max
      end

      def update_hud_progress(total_points, estimated_total, progress_percent, elapsed: nil, bytes_processed: nil)
        return unless defined?(PointCloudPlugin) && PointCloudPlugin.respond_to?(:tool)

        tool = PointCloudPlugin.tool
        hud = tool&.hud
        return unless hud

        status_text = build_status_text(total_points, estimated_total, progress_percent)
        speed_text = build_speed_text(total_points, elapsed, bytes_processed)

        metrics = { load_status: status_text }
        metrics[:load_speed] = speed_text if speed_text

        hud.update(metrics)
      end

      def update_hud_failure(error)
        return unless defined?(PointCloudPlugin) && PointCloudPlugin.respond_to?(:tool)

        tool = PointCloudPlugin.tool
        hud = tool&.hud
        return unless hud

        hud.update(load_status: "Import failed: #{error.message}")
      end

      def build_status_text(total_points, estimated_total, progress_percent)
        loaded_points = format_points(total_points)

        if estimated_total && progress_percent
          total_points_label = format_points(estimated_total)
          percent_label = format('%.0f%%', progress_percent)
          bar = progress_bar(progress_percent)
          "Loading: #{bar} #{percent_label} (#{loaded_points} / #{total_points_label} points)"
        else
          "Loading: #{loaded_points} points"
        end
      end

      def build_speed_text(total_points, elapsed, bytes_processed)
        return unless elapsed && elapsed.positive?

        points_per_second = total_points.to_f / elapsed
        parts = [format('%s pts/s', format_points(points_per_second))]

        if bytes_processed && bytes_processed.positive?
          bytes_per_second = bytes_processed / elapsed
          parts << format('%s/s', format_bytes(bytes_per_second))
        end

        "Speed: #{parts.join(' | ')}"
      end

      def format_points(value)
        number = value.to_f
        thresholds = [
          [1_000_000_000, 'B'],
          [1_000_000, 'M'],
          [1_000, 'K']
        ]

        thresholds.each do |limit, suffix|
          next unless number >= limit

          scaled = number / limit
          return format('%.1f%s', scaled, suffix)
        end

        number.round.to_s
      end

      def format_bytes(value)
        number = value.to_f
        units = %w[B KB MB GB TB]
        index = 0

        while number >= 1024.0 && index < units.length - 1
          number /= 1024.0
          index += 1
        end

        if number >= 10
          format('%.0f %s', number, units[index])
        else
          format('%.1f %s', number, units[index])
        end
      end

      def progress_bar(progress_percent, width = 20)
        return ('-' * width) unless progress_percent

        clamped = progress_percent.clamp(0.0, 100.0)
        filled = ((clamped / 100.0) * width).round
        "[#{'=' * filled}#{'.' * (width - filled)}]"
      end

      def monotonic_time
        if Process.const_defined?(:CLOCK_MONOTONIC)
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        else
          Process.clock_gettime(:monotonic)
        end
      rescue Errno::EINVAL
        Time.now.to_f
      end

      def elapsed_time
        return 0.0 unless @start_time

        monotonic_time - @start_time
      end

      def processed_bytes(total_points, estimated_total, size_in_bytes)
        return unless total_points.positive? && estimated_total && estimated_total.positive? && size_in_bytes

        ratio = [total_points.to_f / estimated_total, 1.0].min
        size_in_bytes * ratio
      end

      def file_size_bytes
        File.size?(path)
      rescue Errno::ENOENT
        nil
      end

      def log_start(size_in_bytes, estimated_total)
        return unless defined?(PointCloudPlugin)

        info = []
        info << "file=#{File.basename(path)}"
        info << "size=#{format_bytes(size_in_bytes)}" if size_in_bytes
        info << "est_points=#{format_points(estimated_total)}" if estimated_total
        PointCloudPlugin.log("Import started (#{info.join(', ')})")
      end

      def log_progress(total_points, estimated_total, progress_percent, elapsed, bytes_processed)
        return unless defined?(PointCloudPlugin) && progress_percent

        now = monotonic_time
        should_log = (progress_percent - @last_logged_percent >= 5.0) || (now - @last_log_time >= 2.0) || progress_percent >= 99.0
        return unless should_log

        @last_logged_percent = progress_percent
        @last_log_time = now

        points_label = "#{format_points(total_points)} pts"
        percent_label = format('%.0f%%', progress_percent)
        speed_label = build_speed_text(total_points, elapsed, bytes_processed)
        eta_label = eta_text(total_points, estimated_total, elapsed)

        message_parts = [percent_label, points_label]
        message_parts << speed_label if speed_label
        message_parts << eta_label if eta_label
        PointCloudPlugin.log("Import progress #{message_parts.compact.join(' | ')}")
      end

      def eta_text(total_points, estimated_total, elapsed)
        return unless estimated_total && elapsed && elapsed.positive? && total_points.positive?

        remaining_points = estimated_total - total_points
        return if remaining_points <= 0

        points_per_second = total_points.to_f / elapsed
        return if points_per_second <= 0

        eta_seconds = remaining_points / points_per_second
        "ETA #{format_duration(eta_seconds)}"
      end

      def format_duration(seconds)
        total_seconds = seconds.round
        return '<1s' if total_seconds <= 0

        mins, secs = total_seconds.divmod(60)
        hours, mins = mins.divmod(60)

        if hours.positive?
          format('%dh %02dm', hours, mins)
        elsif mins.positive?
          format('%dm %02ds', mins, secs)
        else
          format('%ds', secs)
        end
      end

      def log_completion(total_points, elapsed, size_in_bytes)
        return unless defined?(PointCloudPlugin)

        speed_text = build_speed_text(total_points, elapsed, size_in_bytes)
        duration = format_duration(elapsed)
        message_parts = ["completed in #{duration}", "total=#{format_points(total_points)} pts"]
        message_parts << speed_text if speed_text
        PointCloudPlugin.log("Import #{message_parts.compact.join(' | ')}")
      end

      def pack(batch)
        packer = Core::ChunkPacker.new
        packer.pack(batch)
      end

      def next_key
        @chunk_index += 1
        "chunk_#{@chunk_index}_#{SecureRandom.hex(4)}"
      end
    end
  end
end
