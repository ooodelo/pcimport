# frozen_string_literal: true

require 'fileutils'

module PointCloudPlugin
  module Core
    # Stores chunks in memory and persists them to disk using an LRU policy.
    class ChunkStore
      Entry = Struct.new(:key, :chunk)

      attr_reader :cache_path, :max_in_memory

      def initialize(cache_path:, max_in_memory: 32)
        @cache_path = cache_path
        @max_in_memory = max_in_memory
        @entries = {}
        @lru = []
        FileUtils.mkdir_p(cache_path)
      end

      def store(key, chunk)
        @entries[key] = chunk
        touch(key)
        evict! if @lru.size > max_in_memory
        persist_to_disk(key, chunk)
      end

      def fetch(key)
        if @entries.key?(key)
          touch(key)
          return @entries[key]
        end

        path = chunk_path(key)
        return unless File.exist?(path)

        chunk = Marshal.load(File.binread(path))
        @entries[key] = chunk
        touch(key)
        evict! if @lru.size > max_in_memory
        chunk
      end

      def prefetch(keys)
        keys.each { |key| fetch(key) }
      end

      def each_in_memory
        return enum_for(:each_in_memory) unless block_given?

        @lru.each do |key|
          yield key, @entries[key]
        end
      end

      def flush!
        @entries.each { |key, chunk| persist_to_disk(key, chunk) }
        @entries.clear
        @lru.clear
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

      def evict!
        while @lru.size > max_in_memory
          key = @lru.pop
          @entries.delete(key)
        end
      end
    end
  end
end
