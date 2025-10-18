# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

begin
  require 'sketchup.rb'
  require 'extensions.rb'
rescue LoadError
  # Allow the code to be loaded outside of SketchUp for testing.
end

require_relative 'core/units'
require_relative 'core/chunk'
require_relative 'core/chunk_store'
require_relative 'core/readers/reader_base'
require_relative 'core/readers/ply_reader'
require_relative 'core/readers/xyz_reader'
require_relative 'core/spatial/morton'
require_relative 'core/spatial/index_builder'
require_relative 'core/spatial/frustum'
require_relative 'core/spatial/knn'
require_relative 'core/lod/reservoir'
require_relative 'core/lod/prefetcher'
require_relative 'core/lod/pipeline'
require_relative 'bridge/main_thread_queue'
require_relative 'bridge/import_job'
require_relative 'bridge/point_cloud_manager'
require_relative 'ui/tool_pointcloud'
require_relative 'ui/hud'
require_relative 'ui/dialog_settings'

module PointCloudPlugin
  EXTENSION_ID = 'com.example.pointcloud'
  EXTENSION_NAME = 'Point Cloud Importer'
  EXTENSION_VERSION = '0.1.0'

  module_function

  def manager
    @manager ||= Bridge::PointCloudManager.new
  end

  def tool
    @tool ||= UI::ToolPointCloud.new(manager)
  end

  def setup_menu
    return unless defined?(::UI)

    menu = ::UI.menu('File')
    menu.add_item('Import Point Cloud...') { start_import }
    menu.add_item('Point Cloud Settings') { tool.settings_dialog.show }
  end

  def start_import
    path = if defined?(::UI)
             ::UI.openpanel('Import Point Cloud', nil, 'Point Clouds|*.ply;*.xyz||')
           end
    return unless path

    reader = build_reader(path)
    cache_root = File.join(Dir.tmpdir, 'pointcloud_cache')
    FileUtils.mkdir_p(cache_root)
    cache_path = File.join(cache_root, File.basename(path, '.*'))
    chunk_store = Core::ChunkStore.new(cache_path: cache_path)
    pipeline = Core::Lod::Pipeline.new(chunk_store: chunk_store)
    job = Bridge::ImportJob.new(path: path, reader: reader, pipeline: pipeline, queue: manager.queue)

    job.define_singleton_method(:on_chunk) do |key, chunk|
      PointCloudPlugin.tool.hud.update(last_chunk: key, last_points: chunk.size)
      PointCloudPlugin.activate_tool
    end

    id = manager.register_cloud(name: File.basename(path), pipeline: pipeline, job: job)
    tool.hud.update("cloud_#{id}" => File.basename(path))

    job.start do
      tool.hud.update(status: 'Import complete')
    end
  end

  def build_reader(path)
    ext = File.extname(path).downcase
    case ext
    when '.ply'
      Core::Readers::PlyReader.new(path)
    when '.xyz'
      Core::Readers::XyzReader.new(path)
    else
      raise ArgumentError, "Unsupported file type: #{ext}"
    end
  end

  def activate_tool
    return unless defined?(Sketchup) && Sketchup.respond_to?(:active_model)

    tools = Sketchup.active_model.tools
    tools.push_tool(tool) unless tools.active_tool?(tool)
  rescue NoMethodError
    tools.push_tool(tool)
  end

end

PointCloudPlugin.setup_menu if defined?(::UI)
