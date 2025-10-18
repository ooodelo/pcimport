# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

begin
  require 'sketchup.rb'
  require 'extensions.rb'
rescue LoadError
  # Allow the code to be loaded outside of SketchUp for testing.
end

module PointCloudPlugin
  unless respond_to?(:log)
    def self.log(message)
      Kernel.puts("[PointCloudPlugin] #{message}")
    rescue StandardError
      nil
    end

    def log(message)
      PointCloudPlugin.log(message)
    end

    module_function :log
  end
end

PointCloudPlugin.log('Loading runtime (pointcloud_plugin/main.rb)') if defined?(PointCloudPlugin)

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
  EXTENSION_ID ||= 'com.example.pointcloud'
  EXTENSION_NAME ||= 'Point Cloud Importer'
  EXTENSION_VERSION ||= '0.1.0'

  module_function

  def manager
    @manager ||= Bridge::PointCloudManager.new
  end

  def tool
    @tool ||= UI::ToolPointCloud.new(manager)
  end

  def setup_menu
    return unless defined?(::UI)
    return if @menu_created

    extensions_menu = ::UI.menu('Extensions')
    submenu = extensions_menu.add_submenu('Point Cloud Importer')
    submenu.add_item('Import Point Cloud...') { start_import }
    submenu.add_item('Point Cloud Settings') { tool.settings_dialog.show }
    submenu.add_item('Activate Point Cloud Tool') { activate_tool }
    @menu_created = true
    log('Menu items registered')
  end

  def setup_toolbar
    return unless defined?(::UI)
    return if @toolbar&.valid?

    command = ::UI::Command.new('Import Point Cloud...') do
      start_import
    end
    command.tooltip = 'Import and activate the point cloud tool'
    command.status_bar_text = 'Open a point cloud file and activate the viewer tool'

    toolbar = ::UI::Toolbar.new('Point Cloud Importer')
    toolbar.add_item(command)
    toolbar.show
    @toolbar = toolbar
    log('Toolbar registered')
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

if defined?(::UI)
  PointCloudPlugin.setup_menu
  PointCloudPlugin.setup_toolbar
end
PointCloudPlugin.log('Runtime load complete') if defined?(PointCloudPlugin)
