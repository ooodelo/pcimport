# frozen_string_literal: true

require 'fileutils'

module PointCloudPlugin
  module Core
    # Stores chunks in memory and persists them to disk using an LRU policy.
    class ChunkStore
      Entry = Struct.new(:key, :chunk, :bytes)

      attr_reader :cache_path, :max_in_memory

      def initialize(cache_path:, max_in_memory: 32)
        @cache_path = cache_path
        @max_in_memory = max_in_memory
        @entries = {}
        @lru = []
        @on_remove_callbacks = []
        @bytes_in_ram = 0
        @memory_limit_bytes = 512 * 1024 * 1024
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

        path = chunk_path(key)
        return unless File.exist?(path)

        chunk = Marshal.load(File.binread(path))
        entry = Entry.new(key, chunk, chunk.memory_bytes)
        @entries[key] = entry
        @bytes_in_ram += entry.bytes
        touch(key)
        evict_until_limit
        chunk
      end

      def prefetch(keys)
        keys.each { |key| fetch(key) }
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

      def memory_limit_mb=(mb)
        @memory_limit_bytes = (mb.to_i * 1024 * 1024)
        evict_until_limit
      end

      private

      def persist_to_disk(key, chunk)
        File.binwrite(chunk_path(key), Marshal.dump(chunk))
      end

      def chunk_path(key)
        File.join(cache_path, "#{key}.chunk")
      end

      def touch(key)
        @lru.delete(key)
        @lru.unshift(key)
      end

      def evict_until_limit
        while @bytes_in_ram > @memory_limit_bytes && @lru.any?
          key = @lru.pop
          entry = @entries.delete(key)
          next unless entry

          @bytes_in_ram -= entry.bytes
          notify_removed(key)
        end
      end

      def notify_removed(key)
        @on_remove_callbacks.each { |callback| callback.call(key) }
      end
    end
  end
end
