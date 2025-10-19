# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

require_relative '../../core/overlay_data_source'

module PointCloudPlugin
  module Core
    class OverlayDataSourceTest < Minitest::Test
      def setup
        @tmpdir = Dir.mktmpdir
      end

      def teardown
        FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
      end

      def test_discovers_chunks_from_manifest
        chunk_path = File.join(@tmpdir, 'abc123.pccb')
        File.binwrite(chunk_path, 'stub')
        manifest = Struct.new(:chunks).new(['abc123.pccb'])

        source = OverlayDataSource.new(cache_path: @tmpdir, manifest: manifest)
        keys = source.chunk_keys

        assert_includes(keys, 'abc123')
        assert_equal(chunk_path, source.chunk_path('abc123'))
        assert(source.chunk?('abc123'))
      end

      def test_discovers_chunks_from_filesystem_when_manifest_missing
        chunk_path = File.join(@tmpdir, 'xyz.pccb')
        File.binwrite(chunk_path, 'stub')
        manifest = Struct.new(:chunks).new([])

        source = OverlayDataSource.new(cache_path: @tmpdir, manifest: manifest)
        source.refresh!

        assert_equal(['xyz'], source.chunk_keys)
      end

      def test_read_samples_returns_empty_when_missing
        manifest = Struct.new(:chunks).new([])
        source = OverlayDataSource.new(cache_path: @tmpdir, manifest: manifest)

        assert_equal([], source.read_samples(limit: 10))
        assert_equal({ sample_ready: false, anchors_ready: false, has_color: false, sample_count: 0 }, source.sample_metadata)
      end
    end
  end
end
