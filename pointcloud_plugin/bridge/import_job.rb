# frozen_string_literal: true

require 'securerandom'
require_relative '../core/chunk'
require_relative '../core/chunk_store'
require_relative '../core/file_hasher'
require_relative '../core/lod/pipeline'
require_relative 'main_thread_queue'

module PointCloudPlugin
  module Bridge
    # Handles background import of point cloud files and forwards chunks to the core pipeline.
    class ImportJob
      DEFAULT_PREVIEW_THRESHOLD = 0.12
      STREAMING_COMPATIBILITY_FLAG = 'PCIMPORT_STREAMING_COMPAT'

      attr_reader :path, :reader, :pipeline, :queue, :progress, :state, :completion_status, :stage_progress
      attr_accessor :cloud_id
      attr_reader :preview_activation_ratio

      def initialize(path:, reader:, pipeline:, queue: MainThreadQueue.new)
        @path = path
        @reader = reader
        @pipeline = pipeline
        @queue = queue
        @progress = 0.0
        @chunk_index = 0
        @thread = nil
        @preview_ready = false
        @state = :initializing
        @completion_status = :pending
        @stage_progress = default_stage_progress
        @cancelled = false
        @preview_activation_ratio = DEFAULT_PREVIEW_THRESHOLD
        @pending_view_invalidation = false
      end

      def start(&block)
        @on_complete = block
        @thread = Thread.new { run }
      end

      def join
        @thread&.join
      end

      def cancel
        @cancelled = true
      end

      def cancelled?
        @cancelled
      end

      private

      def default_stage_progress
        {
          hash_check: 0.0,
          sampling: 0.0,
          cache_write: 0.0,
          build: 0.0
        }
      end

      def run
        size_in_bytes = file_size_bytes
        estimated_total = estimate_total_points(size_in_bytes)
        @start_time = monotonic_time
        @last_log_time = @start_time
        @last_logged_percent = 0.0

        log_start(size_in_bytes, estimated_total)
        perform_import(
          size_in_bytes: size_in_bytes,
          estimated_total: estimated_total,
          streaming: streaming_compatibility_enabled?
        )
      rescue StandardError => e
        handle_failure(e)
      end

      def perform_import(size_in_bytes:, estimated_total:, streaming: false)
        signature = perform_hash_check
        manifest = pipeline&.chunk_store&.manifest

        if manifest && signature && reuse_cache_from_manifest(
             manifest,
             signature,
             size_in_bytes: size_in_bytes,
             estimated_total: estimated_total,
             streaming: streaming
           )
          return
        end

        manifest.update_source_signature!(signature) if manifest && signature

        total_points = 0
        preview_accumulator = []
        transition_state(:sampling)

        reader.each_batch do |batch|
          break if cancelled?

          preview_points = preview_sample(batch)
          append_preview_samples(preview_accumulator, preview_points)

          batch_points = batch.respond_to?(:size) ? batch.size : Array(batch).size
          total_points += batch_points
          ratio = progress_ratio(total_points, estimated_total)
          update_stage_progress(:sampling, ratio)

          chunk = pack(batch)
          first_chunk = (@chunk_index.zero?)
          transition_state(:cache_write) if first_chunk
          update_stage_progress(:cache_write, ratio)

          break if cancelled?

          key = next_key
          pipeline.submit_chunk(key, chunk)
          preview_became_ready = mark_preview_ready(first_chunk: first_chunk, ratio: ratio)

          @progress = total_points

          progress_percent = ratio.positive? ? (ratio * 100.0) : nil
          elapsed = elapsed_time
          bytes_processed = processed_bytes(total_points, estimated_total, size_in_bytes)
          log_progress(total_points, estimated_total, progress_percent, elapsed, bytes_processed)

          queue.push do
            info = {
              total_points: total_points,
              estimated_total: estimated_total,
              progress_percent: progress_percent,
              first_chunk: first_chunk,
              preview_ready: preview_ready?,
              stage: state,
              stage_progress: @stage_progress.dup,
              preview_points: preview_points
            }

            notify_progress(key, chunk, **info)
            dispatch_to_tool(key, chunk, info) if streaming

            update_hud_progress(
              total_points,
              estimated_total,
              progress_percent,
              elapsed: elapsed,
              bytes_processed: bytes_processed
            )

            activate_preview_layer if preview_became_ready
            @pending_view_invalidation = true
          end
        end

        transition_state(:cache_write) if state == :sampling

        if cancelled?
          handle_cancellation(total_points, estimated_total, size_in_bytes)
          return
        end

        write_preview_sample(preview_accumulator)

        transition_state(:build)
        update_stage_progress(:build, 1.0)

        elapsed = elapsed_time
        @completion_status = :completed
        finalize_stage_completion
        log_completion(total_points, elapsed, size_in_bytes)
        transition_state(:navigating)

        queue.push do
          update_hud_progress(
            total_points,
            estimated_total,
            100.0,
            elapsed: elapsed,
            bytes_processed: size_in_bytes
          )
          flush_pending_view_invalidation
          @on_complete&.call(self)
        end
      end

      def perform_hash_check
        transition_state(:hash_check)
        update_stage_progress(:hash_check, 0.0)

        signature = Core::FileHasher.signature_for(path)

        update_stage_progress(:hash_check, 1.0)
        signature
      end

      def streaming_compatibility_enabled?
        value = ENV.fetch(STREAMING_COMPATIBILITY_FLAG, nil)
        return false if value.nil?

        normalized = value.to_s.strip.downcase
        return false if normalized.empty?

        !%w[0 false no off].include?(normalized)
      rescue StandardError
        false
      end

      def reuse_cache_from_manifest(manifest, signature, size_in_bytes:, estimated_total:, streaming: false)
        return false unless signature.is_a?(Hash)

        current = manifest.source
        return false unless current
        return false unless Core::FileHasher.signatures_match?(current, signature)

        manifest.update_source_signature!(signature)
        manifest.ensure_chunk_inventory!

        total_points = 0
        preview_accumulator = []

        transition_state(:sampling)

        Array(manifest.chunks).each_with_index do |filename, index|
          break if cancelled?

          key = File.basename(filename, File.extname(filename))
          chunk = pipeline&.chunk_store&.fetch(key)
          next unless chunk

          pipeline.submit_chunk(key, chunk)

          points_in_chunk = chunk.respond_to?(:size) ? chunk.size : 0
          total_points += points_in_chunk

          append_preview_samples(preview_accumulator, sample_from_chunk(chunk, PREVIEW_SAMPLE_LIMIT))

          ratio = progress_ratio(total_points, estimated_total)
          update_stage_progress(:sampling, ratio)
          transition_state(:cache_write) if state == :sampling
          update_stage_progress(:cache_write, ratio)

          @preview_ready = true if points_in_chunk.positive?

          progress_percent = ratio.positive? ? (ratio * 100.0) : nil
          elapsed = elapsed_time
          bytes_processed = processed_bytes(total_points, estimated_total, size_in_bytes)
          log_progress(total_points, estimated_total, progress_percent, elapsed, bytes_processed)

          next unless streaming

          queue.push do
            info = {
              total_points: total_points,
              estimated_total: estimated_total,
              progress_percent: progress_percent,
              first_chunk: index.zero?,
              preview_ready: preview_ready?,
              stage: state,
              stage_progress: @stage_progress.dup,
              preview_points: nil
            }

            notify_progress(key, chunk, **info)
            dispatch_to_tool(key, chunk, info)

            update_hud_progress(
              total_points,
              estimated_total,
              progress_percent,
              elapsed: elapsed,
              bytes_processed: bytes_processed
            )

          activate_preview_layer if preview_ready?
          @pending_view_invalidation = true
        end
        end

        transition_state(:cache_write) if state == :sampling

        @progress = total_points

        if cancelled?
          handle_cancellation(total_points, estimated_total, size_in_bytes)
          return true
        end

        write_preview_sample(preview_accumulator)

        transition_state(:build)
        update_stage_progress(:build, 1.0)

        elapsed = elapsed_time
        @completion_status = :completed
        finalize_stage_completion
        log_completion(total_points, elapsed, size_in_bytes)
        transition_state(:navigating)

        queue.push do
          update_hud_progress(
            total_points,
            estimated_total,
            100.0,
            elapsed: elapsed,
            bytes_processed: size_in_bytes
          )
          flush_pending_view_invalidation
          @on_complete&.call(self)
        end

        true
      end

      def append_preview_samples(storage, samples)
        return unless storage.is_a?(Array)

        remaining = PREVIEW_SAMPLE_LIMIT - storage.length
        return if remaining <= 0

        Array(samples).each do |sample|
          break if remaining <= 0

          storage << (sample.is_a?(Hash) ? sample.dup : sample)
          remaining -= 1
        end
      rescue StandardError
        nil
      end

      def sample_from_chunk(chunk, limit)
        return [] unless chunk.respond_to?(:each_point)

        samples = []
        chunk.each_point do |point|
          samples << (point.is_a?(Hash) ? point.dup : point)
          break if samples.length >= limit
        end
        samples
      rescue StandardError
        []
      end

      def write_preview_sample(points)
        return if points.nil? || points.empty?

        store = pipeline&.chunk_store
        manifest = store&.manifest
        cache_path = store&.cache_path
        return unless manifest && cache_path

        require 'fileutils'
        require 'json'

        FileUtils.mkdir_p(cache_path)
        filename = 'preview.json'
        path = File.join(cache_path, filename)

        serialized = Array(points).first(PREVIEW_SAMPLE_LIMIT).filter_map do |point|
          serialize_preview_point(point)
        end

        File.binwrite(path, JSON.pretty_generate(serialized))
        manifest.preview_file = filename if manifest.respond_to?(:preview_file=)
        manifest.write! if manifest.respond_to?(:write!)
      rescue StandardError => e
        warn("Failed to write preview sample: #{e.message}")
      end

      def serialize_preview_point(point)
        position = nil
        color = nil
        intensity = nil

        if point.is_a?(Hash)
          position = point[:position] || point['position']
          color = point[:color] || point['color']
          intensity = point[:intensity] || point['intensity']
        elsif point.respond_to?(:position)
          position = point.position
          color = point.respond_to?(:color) ? point.color : nil
          intensity = point.respond_to?(:intensity) ? point.intensity : nil
        elsif point.respond_to?(:to_a)
          position = point.to_a
        end

        coords = Array(position).first(3)
        return unless coords.length == 3

        data = { position: coords.map { |value| value.to_f } }

        if color
          rgb = Array(color).first(3).map do |value|
            begin
              Float(value)
            rescue ArgumentError, TypeError
              value.to_i
            end
          end
          data[:color] = rgb if rgb.any?
        end

        if intensity
          begin
            data[:intensity] = Float(intensity)
          rescue ArgumentError, TypeError
            nil
          end
        end

        data
      rescue StandardError
        nil
      end

      def flush_pending_view_invalidation
        return unless @pending_view_invalidation

        invalidate_active_view
        @pending_view_invalidation = false
      end

      def notify_progress(key, chunk, total_points: nil, estimated_total: nil, progress_percent: nil, first_chunk: false, preview_ready: false, stage: nil, stage_progress: nil, preview_points: nil)
        # Hook for UI updates; by default does nothing but can be extended.
        if respond_to?(:on_chunk)
          begin
            on_chunk(
              key,
              chunk,
              total_points: total_points,
              estimated_total: estimated_total,
              progress_percent: progress_percent,
              first_chunk: first_chunk,
              preview_ready: preview_ready,
              stage: stage,
              stage_progress: stage_progress,
              preview_points: preview_points
            )
          rescue ArgumentError
            on_chunk(key, chunk)
          end
        end
      end

      def preview_ready?
        @preview_ready
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

      def preview_activation_ratio=(value)
        numeric =
          case value
          when Numeric then value.to_f
          else
            begin
              Float(value)
            rescue ArgumentError, TypeError
              nil
            end
          end

        @preview_activation_ratio =
          if numeric.nil?
            DEFAULT_PREVIEW_THRESHOLD
          else
            numeric.clamp(0.0, 1.0)
          end
      end

      def mark_preview_ready(first_chunk:, ratio: 0.0)
        return false if preview_ready?

        threshold = @preview_activation_ratio || DEFAULT_PREVIEW_THRESHOLD
        ratio = ratio.to_f

        if threshold <= 0.0
          @preview_ready = true if first_chunk || ratio.positive?
        elsif ratio >= threshold
          @preview_ready = true
        elsif !estimated_progress_available?(ratio) && first_chunk
          # Estimated progress is unavailable; prefer to show something.
          @preview_ready = true
        end

        @preview_ready
      end

      def activate_preview_layer
        return unless defined?(PointCloudPlugin)

        tool = PointCloudPlugin.respond_to?(:tool) ? PointCloudPlugin.tool : nil
        return unless tool

        if tool.respond_to?(:preview_ready=)
          tool.preview_ready = true
        elsif tool.respond_to?(:enable_preview!)
          tool.enable_preview!
        else
          tool.instance_variable_set(:@preview_ready, true)
        end
      rescue StandardError => e
        warn("Failed to activate preview layer: #{e.class}: #{e.message}")
      end

      def invalidate_active_view
        return unless defined?(Sketchup) && Sketchup.respond_to?(:active_model)

        model = Sketchup.active_model
        view = model&.active_view
        return unless view && view.respond_to?(:invalidate)

        view.invalidate
      rescue StandardError => e
        warn("Failed to invalidate active view: #{e.class}: #{e.message}")
      end

      PREVIEW_SAMPLE_LIMIT = 512

      def preview_sample(batch)
        return [] if preview_ready?

        array = Array(batch)
        return [] if array.empty?

        array.first([array.length, PREVIEW_SAMPLE_LIMIT].min).map do |point|
          point.is_a?(Hash) ? point.dup : point
        end
      rescue StandardError
        []
      end

      def transition_state(new_state)
        new_state = new_state.to_sym
        return if @state == new_state

        @state = new_state
        queue.push { dispatch_state_change(new_state) }
      end

      def dispatch_state_change(new_state)
        tool = active_tool
        return unless tool && tool.respond_to?(:handle_import_state)

        tool.handle_import_state(job: self, state: new_state, stage_progress: @stage_progress.dup)
      end

      def dispatch_to_tool(key, chunk, info)
        tool = active_tool
        return unless tool

        PointCloudPlugin.activate_tool if defined?(PointCloudPlugin) && PointCloudPlugin.respond_to?(:activate_tool)

        if tool.respond_to?(:handle_import_state)
          tool.handle_import_state(job: self, state: info[:stage] || state, stage_progress: info[:stage_progress])
        end

        if tool.respond_to?(:handle_import_chunk)
          tool.handle_import_chunk(job: self, key: key, chunk: chunk, info: info)
        end
      end

      def active_tool
        return unless defined?(PointCloudPlugin)
        return unless PointCloudPlugin.respond_to?(:tool)

        PointCloudPlugin.tool
      end

      def update_stage_progress(stage, ratio)
        return unless @stage_progress.key?(stage)

        @stage_progress[stage] = ratio.clamp(0.0, 1.0)
      end

      def progress_ratio(total_points, estimated_total)
        return 0.0 unless estimated_total && estimated_total.positive?

        [total_points.to_f / estimated_total, 1.0].min
      end

      def estimated_progress_available?(ratio)
        ratio && ratio.positive?
      end

      def finalize_stage_completion
        @stage_progress.keys.each { |key| @stage_progress[key] = 1.0 }
        transition_state(:build) unless %i[build navigating].include?(@state)
      end

      def handle_cancellation(total_points, estimated_total, size_in_bytes)
        @completion_status = :cancelled
        transition_state(:cancelled)
        pipeline.chunk_store.flush! if pipeline.respond_to?(:chunk_store)
        elapsed = elapsed_time
        bytes_processed = processed_bytes(total_points, estimated_total, size_in_bytes)

        queue.push do
          update_hud_progress(total_points, estimated_total, nil, elapsed: elapsed, bytes_processed: bytes_processed)
          flush_pending_view_invalidation
          @on_complete&.call(self)
        end
      end

      def handle_failure(error)
        warn("Import failed: #{error.class}: #{error.message}\n#{Array(error.backtrace).join("\n")}")
        @completion_status = :failed
        transition_state(:cancelled)
        queue.push do
          update_hud_failure(error)
          flush_pending_view_invalidation
          if defined?(UI) && UI.respond_to?(:messagebox)
            UI.messagebox("Point cloud import failed: #{error.message}")
          end
          @on_complete&.call(self)
        end
      end
    end
  end
end
