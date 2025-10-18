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
        estimated_total = estimate_total_points
        first_chunk_shown = false

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

            update_hud_progress(total_points, estimated_total, progress_percent)
          end
        end

        queue.push do
          update_hud_progress(total_points, estimated_total, 100.0)
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

      def estimate_total_points
        size_in_bytes = File.size?(path)
        return unless size_in_bytes

        average_point_size = 32.0
        [(size_in_bytes / average_point_size).ceil, 1].max
      rescue Errno::ENOENT
        nil
      end

      def update_hud_progress(total_points, estimated_total, progress_percent)
        return unless defined?(PointCloudPlugin) && PointCloudPlugin.respond_to?(:tool)

        tool = PointCloudPlugin.tool
        hud = tool&.hud
        return unless hud

        status_text = build_status_text(total_points, estimated_total, progress_percent)
        hud.update(load_status: status_text)
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
          "Loading: #{percent_label} (#{loaded_points} / #{total_points_label} points)"
        else
          "Loading: #{loaded_points} points"
        end
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
