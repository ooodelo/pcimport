# frozen_string_literal: true

require 'fileutils'

require_relative 'chunk_serializer'

module PointCloudPlugin
  module Core
    # Stores chunks in memory and persists them to disk using an LRU policy.
    class ChunkStore
      Entry = Struct.new(:key, :chunk, :bytes)

      attr_reader :cache_path, :max_in_memory, :memory_limit_bytes, :manifest

      DEFAULT_MEMORY_LIMIT_BYTES = 512 * 1024 * 1024

      def initialize(cache_path:, max_in_memory: 32, memory_limit_mb: nil, manifest: nil)
        @cache_path = cache_path
        @max_in_memory = max_in_memory
        @entries = {}
        @lru = []
        @on_remove_callbacks = []
        @bytes_in_ram = 0
        @memory_limit_bytes = normalize_memory_limit(memory_limit_mb)
        @memory_pressure_callbacks = []
        @memory_pressure_notified = false
        @serializer = ChunkSerializer.new
        @manifest = manifest
        FileUtils.mkdir_p(cache_path)
      end

      def store(key, chunk)
        previous = @entries[key]
        @bytes_in_ram -= previous.bytes if previous

        entry = Entry.new(key, chunk, chunk.memory_bytes)
        @entries[key] = entry
        @bytes_in_ram += entry.bytes
        touch(key)
        evict_until_limit
        persist_to_disk(key, chunk)
      end

      def fetch(key)
        if (entry = @entries[key])
          touch(key)
          return entry.chunk
        end

        chunk = load_chunk(key)
        return unless chunk

        entry = Entry.new(key, chunk, chunk.memory_bytes)
        @entries[key] = entry
        @bytes_in_ram += entry.bytes
        touch(key)
        evict_until_limit
        chunk
      end

      def prefetch(keys)
        keys.each { |k| fetch(k) }
      end

      def each_in_memory
        return enum_for(:each_in_memory) unless block_given?

        @lru.each do |key|
          entry = @entries[key]
          yield key, entry.chunk if entry
        end
      end

      def flush!
        @entries.each do |key, entry|
          persist_to_disk(key, entry.chunk)
          notify_removed(key)
        end
        @entries.clear
        @lru.clear
        @bytes_in_ram = 0
      end

      def release(key)
        entry = @entries.delete(key)
        @bytes_in_ram -= entry.bytes if entry
        @lru.delete(key)
        notify_removed(key)
      end

      def on_remove(&block)
        return unless block

        @on_remove_callbacks << block
      end

      def on_memory_pressure(&block)
        return unless block

        @memory_pressure_callbacks << block
      end

      def memory_limit_mb=(mb)
        @memory_limit_bytes = normalize_memory_limit(mb)
        @memory_pressure_notified = false
        evict_until_limit
      end

      private

      attr_reader :serializer

      def normalize_memory_limit(mb)
        return DEFAULT_MEMORY_LIMIT_BYTES if mb.nil?

        bytes = mb.to_i * 1024 * 1024
        bytes.positive? ? bytes : 0
      end

      def persist_to_disk(key, chunk)
        path = chunk_path(key)
        serializer.write(path, chunk)
        register_chunk_file(File.basename(path))
      rescue StandardError
        FileUtils.rm_f(path)
        raise
      end

      def chunk_path(key)
        File.join(cache_path, "#{key}.pccb")
      end

      def legacy_chunk_path(key)
        File.join(cache_path, "#{key}.chunk")
      end

      def touch(key)
        @lru.delete(key)
        @lru.unshift(key)
      end

      def evict_until_limit
        freed_bytes = 0
        while @bytes_in_ram > @memory_limit_bytes && @lru.any?
          key = @lru.pop
          entry = @entries.delete(key)
          next unless entry

          @bytes_in_ram -= entry.bytes
          freed_bytes += entry.bytes
          notify_removed(key)
        end

        notify_memory_pressure(freed_bytes) if freed_bytes.positive?
      end

      def load_chunk(key)
        chunk = ensure_current_format(key)
        return chunk if chunk

        serializer.read(chunk_path(key))
      rescue ChunkSerializer::CorruptedData, ChunkSerializer::InvalidHeader
        handle_corrupted_chunk(key)
      rescue Errno::ENOENT
        nil
      end

      def ensure_current_format(key)
        path = chunk_path(key)
        return nil if File.exist?(path)

        legacy_path = legacy_chunk_path(key)
        return nil unless File.exist?(legacy_path)

        chunk = Marshal.load(File.binread(legacy_path))
        persist_to_disk(key, chunk)
        FileUtils.rm_f(legacy_path)
        remove_chunk_file(File.basename(legacy_path))
        chunk
      rescue StandardError
        FileUtils.rm_f(legacy_path) if legacy_path && File.exist?(legacy_path)
        nil
      end

      def handle_corrupted_chunk(key)
        path = chunk_path(key)
        FileUtils.rm_f(path)
        remove_chunk_file(File.basename(path))
        ensure_current_format(key)
      rescue StandardError
        nil
      end

      def register_chunk_file(filename)
        return unless manifest

        if manifest.respond_to?(:chunks=)
          current = Array(manifest.chunks) - [filename]
          current << filename
          manifest.chunks = current.sort
        end

        if manifest.respond_to?(:chunk_format_version=)
          manifest.chunk_format_version = ChunkSerializer::VERSION
        elsif manifest.respond_to?(:version=)
          manifest.version = ChunkSerializer::VERSION
        end

        manifest.write! if manifest.respond_to?(:write!)
      rescue StandardError
        nil
      end

      def remove_chunk_file(filename)
        return unless manifest

        if manifest.respond_to?(:chunks=)
          manifest.chunks = Array(manifest.chunks) - [filename]
        end

        manifest.write! if manifest.respond_to?(:write!)
      rescue StandardError
        nil
      end

      def notify_removed(key)
        @on_remove_callbacks.each { |callback| callback.call(key) }
      end

      def notify_memory_pressure(freed_bytes)
        return if @memory_pressure_notified
        return if @memory_pressure_callbacks.empty?

        @memory_pressure_notified = true
        @memory_pressure_callbacks.each do |callback|
          callback.call(freed_bytes, @memory_limit_bytes)
        end
      end
    end
  end
end
