# 离线测试：视口截图（View#write_image）拍出全白时，缩略图视图改用组件缩略图离屏渲染。
# 用法：ruby tests/thumbnail_view_fallback_test.rb <解压后的 su_linkhub 目录>
# 不需要 SketchUp：用最小替身模拟 Model / View / ComponentDefinition / ImageRep。
# 旧版 v0.13.7.9：两张视图都抛出“缩略图视图为空白”，测试失败。
# 新版 v0.13.7.10：视图文件由组件缩略图写出，且能通过主体验收。
require 'fileutils'
require 'json'
require 'securerandom'
require 'tmpdir'

dir = ARGV[0] || 'su_linkhub'

module Geom
  class Point3d
    attr_reader :x, :y, :z
    def initialize(x = 0, y = 0, z = 0); @x, @y, @z = x.to_f, y.to_f, z.to_f; end
    def transform(_t); self; end
    def offset(v, d = nil)
      d ||= 1.0
      len = v.length
      Point3d.new(x + v.x / len * d, y + v.y / len * d, z + v.z / len * d)
    end
    def vector_to(p); Vector3d.new(p.x - x, p.y - y, p.z - z); end
    def to_a; [x, y, z]; end
  end
  class Vector3d
    attr_reader :x, :y, :z
    def initialize(x = 0, y = 0, z = 0)
      x, y, z = x if x.is_a?(Array)
      @x, @y, @z = x.to_f, y.to_f, z.to_f
    end
    def length; Math.sqrt(x * x + y * y + z * z); end
    def normalize!; l = length; @x /= l; @y /= l; @z /= l; self; end
    def cross(o); Vector3d.new(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x); end
    def dot(o); x * o.x + y * o.y + z * o.z; end
    def to_a; [x, y, z]; end
  end
  class BoundingBox
    def initialize; @pts = []; end
    def add(p); @pts << p; end
    def min; Point3d.new(@pts.map(&:x).min, @pts.map(&:y).min, @pts.map(&:z).min); end
    def max; Point3d.new(@pts.map(&:x).max, @pts.map(&:y).max, @pts.map(&:z).max); end
    def center; a = min; b = max; Point3d.new((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2); end
    def width; max.x - min.x; end
    def height; max.y - min.y; end
    def depth; max.z - min.z; end
  end
  class Transformation
    def self.translation(_v); new; end
  end
end

module Sketchup
  def self.version; '24.0.0'; end
  class Color
    def initialize(*rgb); @rgb = rgb; end
  end
  class Camera
    attr_accessor :height, :aspect_ratio
    attr_reader :eye, :target, :up
    def initialize(eye, target, up, _persp = true); @eye, @target, @up = eye, target, up; end
    def perspective?; false; end
  end
  class ImageRep
    attr_reader :width, :height, :bits_per_pixel, :row_padding, :data
    @@store = {}
    def self.store; @@store; end
    def load_file(p); @width, @height, @bits_per_pixel, @row_padding, @data = @@store.fetch(p); end
  end
end

# 替身 ImageRep 按路径保存像素；文件复制时同步复制像素。
module FileUtils
  class << self
    alias_method :__orig_cp, :cp
    def cp(a, b, **kw)
      __orig_cp(a, b, **kw)
      Sketchup::ImageRep.store[b.to_s] = Sketchup::ImageRep.store[a.to_s] if Sketchup::ImageRep.store.key?(a.to_s)
    end
  end
end

def synthetic_image(path, subject:, size: 256)
  data = ''.b
  size.times do |y|
    size.times do |x|
      inside = subject && x.between?(size / 4, size * 3 / 4) && y.between?(size / 4, size * 3 / 4)
      data << (inside ? [120, 150, 190] : [255, 255, 255]).pack('C*')
    end
  end
  Sketchup::ImageRep.store[path] = [size, size, 24, 0, data]
  File.write(path, 'png')
  true
end

class FakeView
  attr_accessor :camera
  def invalidate; end
  def refresh; end
  def vpwidth; 1600; end
  def vpheight; 900; end
  # 模拟“视口截图拍空”：文件格式正确，但整张都是白色。
  def write_image(opts); synthetic_image(opts[:filename], subject: false, size: opts[:width]); end
end

class FakeDefinition
  attr_accessor :thumbnail_camera
  attr_reader :refreshed
  def valid?; true; end
  def refresh_thumbnail; @refreshed = true; end
  # 组件缩略图离屏渲染：有主体。
  def save_thumbnail(path); synthetic_image(path, subject: true); end
end

class FakeEntities
  def initialize; @list = []; end
  def to_a; @list.dup; end
  def length; @list.length; end
  def add_instance(defn, _t); @list << defn; end
end

class FakeList < Array
  def load(_path); @defn ||= FakeDefinition.new; end
end

class FakeModel
  attr_reader :definitions, :entities, :active_view
  def initialize
    @definitions = FakeList.new
    @entities = FakeEntities.new
    @active_view = FakeView.new
  end
  def selection; @selection ||= []; end
  def layers; []; end
  def active_path; nil; end
  def bounds; nil; end
  def start_operation(*); end
  def abort_operation; end
end

module GavinTools
  module SULinkHubMultiSpace
    module Runtime
      TEMP_VISUAL_PROXY_DIR = File.join(Dir.tmpdir, "linkhub_thumbview_test_#{Process.pid}")
      SOFT_LIBRARY_THUMBNAIL_MARGIN = 1.15
    end
  end
end

load File.join(dir, 'image_media.rb')
load File.join(dir, 'thumbnail_views.rb')

class Harness
  include GavinTools::SULinkHubMultiSpace::Runtime
  attr_reader :logs
  def initialize(out); @out = out; @logs = []; end
  def log(m); @logs << m; end
  def log_exception(m, e); @logs << "#{m}: #{e.message}"; end
  def soft_library_thumbnail_dir(_root); @out; end
  def soft_model_id_for_path(_p); 'abcdef0123456789abcd'; end
  def capture_active_view_state(_m); nil; end
  def restore_active_view_state(*); end
  def begin_soft_heavy_interaction(*); end
  def end_soft_heavy_interaction(*); end
  def load_definition_compat(defs, path); defs.load(path); end
  def soft_definition_bounds_values(_d); [0, 0, 0, 40, 20, 30]; end
  def soft_bounds_values_valid?(v); v.is_a?(Array) && v.length == 6; end
  def identity_transformation; Geom::Transformation.new; end
  def soft_thumbnail_bounds_points(values, _t = nil)
    x0, y0, z0, x1, y1, z1 = values.map(&:to_f)
    [[x0, y0, z0], [x1, y0, z0], [x1, y1, z0], [x0, y1, z0],
     [x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]].map { |p| Geom::Point3d.new(*p) }
  end
  def soft_visual_proxy_root_distant_capture_shift(*); nil; end
  def soft_visual_proxy_texture_size(_w, _h, max); [max, max]; end
  def with_soft_bright_thumbnail_style(*); yield; end
  def soft_visual_proxy_set_background!(*); true; end
  def cleanup_soft_thumbnail_definitions!(*); true; end
  def linkhub_mv(a, b)
    Sketchup::ImageRep.store[b] = Sketchup::ImageRep.store.delete(a)
    File.rename(a, b)
  end
end

out = Dir.mktmpdir('linkhub_thumbview_out')
src = File.join(out, 'model.skp')
File.write(src, 'skp')
h = Harness.new(out)
model = FakeModel.new
failures = []
%w[a b].each do |view|
  begin
    h.render_soft_thumbnail_view_world!(model, src, view, out, local_stage: true)
  rescue StandardError => e
    failures << "#{view}: #{e.message}"
    next
  end
  [false, true].each do |hd|
    path = h.soft_thumbnail_view_path(src, view, out, hd: hd)
    ok = File.file?(path) && h.soft_thumbnail_view_content_valid?(path)
    puts "view #{view}#{hd ? ' hd' : ''}: #{ok ? 'has subject' : 'BLANK/missing'}"
    failures << "#{view}#{hd ? ' hd' : ''} blank" unless ok
  end
end
h.logs.each { |m| puts "  log: #{m}" }
abort("FAIL: #{failures.join('; ')}") unless failures.empty?
puts 'PASS'
