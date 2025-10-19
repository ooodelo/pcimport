# frozen_string_literal: true

module PointCloudPlugin
  module Core
    # Helpers for working with cached preview samples generated during import.
    module SampleCache
      SAMPLE_FILE_NAME = 'sample_300k.bin'
      SAMPLE_MAGIC = 'PCS1'.b
      SAMPLE_VERSION = 1
      FLAG_HAS_COLOR = 0x01
      FLAG_HAS_ANCHOR = 0x02
      HEADER_SIZE = 14

      module_function

      def sample_path(cache_path)
        return unless cache_path

        File.join(cache_path, SAMPLE_FILE_NAME)
      end

      def metadata(cache_path)
        header = read_header(cache_path)
        return default_metadata unless header

        magic, version, count, flags = header
        return default_metadata unless magic == SAMPLE_MAGIC && version == SAMPLE_VERSION

        {
          sample_ready: count.positive?,
          anchors_ready: (flags & FLAG_HAS_ANCHOR).positive?,
          has_color: (flags & FLAG_HAS_COLOR).positive?,
          sample_count: count
        }
      rescue StandardError
        default_metadata
      end

      def read_samples(cache_path, limit: nil)
        header, data = read_file(cache_path)
        return [] unless header && data

        magic, version, count, flags = header
        return [] unless magic == SAMPLE_MAGIC && version == SAMPLE_VERSION

        has_color = (flags & FLAG_HAS_COLOR).positive?
        offset = HEADER_SIZE
        record_size = 12 + (has_color ? 3 : 0) + 1
        desired_count = limit ? [limit.to_i, count].min : count

        samples = []
        count.times do
          break if samples.length >= desired_count
          break if offset + record_size > data.bytesize

          coords = data[offset, 12].unpack('e3')
          offset += 12
          offset += 3 if has_color
          anchor_flag = data.getbyte(offset) || 0
          offset += 1

          samples << { position: coords, anchor: anchor_flag.positive? }
        end

        samples
      rescue StandardError
        []
      end

      def default_metadata
        {
          sample_ready: false,
          anchors_ready: false,
          has_color: false,
          sample_count: 0
        }
      end

      def read_header(cache_path)
        path = sample_path(cache_path)
        return unless path && File.file?(path)

        data = File.binread(path, HEADER_SIZE)
        return unless data && data.bytesize == HEADER_SIZE

        data.unpack('a4 S< L< L<')
      rescue StandardError
        nil
      end

      def read_file(cache_path)
        path = sample_path(cache_path)
        return unless path && File.file?(path)

        data = File.binread(path)
        return unless data && data.bytesize >= HEADER_SIZE

        header = data[0, HEADER_SIZE].unpack('a4 S< L< L<')
        [header, data]
      rescue StandardError
        [nil, nil]
      end
    end
  end
end

