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

      def initialize(path:, reader:, pipeline:, queue: MainThreadQueue.new, input_unit: :meter, offset: { x: 0.0, y: 0.0, z: 0.0 })
        @path = path
        @reader = reader
        @pipeline = pipeline
        @queue = queue
        @progress = 0.0
        @chunk_index = 0
        @thread = nil
        @input_unit = input_unit
        @offset = offset
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
        reader.each_batch do |batch|
          total_points += batch.size
          chunk = pack(batch)
          first_chunk = (@chunk_index.zero?)
          key = next_key
          pipeline.submit_chunk(key, chunk)
          @progress = total_points
          queue.push do
            notify_progress(
              key,
              chunk,
              total_points: total_points,
              first_chunk: first_chunk
            )
          end
        end

        queue.push { @on_complete&.call(self) }
      rescue StandardError => e
        queue.push { warn("Import failed: #{e.message}") }
      end

      def notify_progress(key, chunk, total_points: nil, first_chunk: false)
        # Hook for UI updates; by default does nothing but can be extended.
        if respond_to?(:on_chunk)
          begin
            on_chunk(key, chunk, total_points: total_points, first_chunk: first_chunk)
          rescue ArgumentError
            on_chunk(key, chunk)
          end
        end
      end

      def pack(batch)
        packer = Core::ChunkPacker.new(input_unit: @input_unit, offset: @offset)
        packer.pack(batch)
      end

      def next_key
        @chunk_index += 1
        "chunk_#{@chunk_index}_#{SecureRandom.hex(4)}"
      end
    end
  end
end
