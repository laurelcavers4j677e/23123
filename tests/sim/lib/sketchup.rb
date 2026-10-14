# frozen_string_literal: true
# Minimal fake SketchUp API, enough to run SU LinkHub ingest code paths on Linux.
require 'json'
require 'fileutils'

module Geom
  class Vector3d
    attr_accessor :x, :y, :z
    def initialize(x = 0.0, y = 0.0, z = 0.0)
      x, y, z = x.to_a if x.respond_to?(:to_a) && !x.is_a?(Numeric)
      @x, @y, @z = x.to_f, y.to_f, z.to_f
    end
    def to_a = [x, y, z]
    def length = Math.sqrt(x * x + y * y + z * z)
    def valid? = length > 1.0e-12
    def normalize = (l = length; l.zero? ? Vector3d.new(0, 0, 0) : Vector3d.new(x / l, y / l, z / l))
    def normalize! = (n = normalize; @x, @y, @z = n.x, n.y, n.z; self)
    def cross(o) = Vector3d.new(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    alias * cross
    def dot(o) = x * o.x + y * o.y + z * o.z
    def %(o) = dot(o)
    def +(o) = Vector3d.new(x + o.x, y + o.y, z + o.z)
    def -(o) = Vector3d.new(x - o.x, y - o.y, z - o.z)
    def reverse = Vector3d.new(-x, -y, -z)
    def length=(l); (n = normalize; @x, @y, @z = n.x * l, n.y * l, n.z * l); end
    def transform(t) = t.apply_vector(self)
    def parallel?(o) = cross(o).length < 1.0e-9 * [length * o.length, 1e-300].max
    def samedirection?(o) = parallel?(o) && dot(o) > 0
    def unitvector? = (length - 1.0).abs < 1e-9
    def angle_between(o) = Math.acos([[dot(o) / (length * o.length), 1.0].min, -1.0].max)
    def [](i) = to_a[i]
    def clone = Vector3d.new(x, y, z)
    def inspect = "V(#{x}, #{y}, #{z})"
  end

  class Point3d
    attr_accessor :x, :y, :z
    def initialize(x = 0.0, y = 0.0, z = 0.0)
      x, y, z = x.to_a if x.respond_to?(:to_a) && !x.is_a?(Numeric)
      @x, @y, @z = x.to_f, y.to_f, z.to_f
    end
    def to_a = [x, y, z]
    def [](i) = to_a[i]
    def transform(t) = t.apply_point(self)
    def transform!(t) = (p = transform(t); @x, @y, @z = p.x, p.y, p.z; self)
    def distance(o) = Math.sqrt((x - o.x)**2 + (y - o.y)**2 + (z - o.z)**2)
    def vector_to(o) = Vector3d.new(o.x - x, o.y - y, o.z - z)
    def -(o) = o.is_a?(Point3d) ? Vector3d.new(x - o.x, y - o.y, z - o.z) : Point3d.new(x - o.x, y - o.y, z - o.z)
    def +(v) = Point3d.new(x + v.x, y + v.y, z + v.z)
    def offset(v, len = nil)
      v = v.normalize.tap { |n| n.x *= len; n.y *= len; n.z *= len } if len
      Point3d.new(x + v.x, y + v.y, z + v.z)
    end
    def ==(o) = o.respond_to?(:x) && distance(Point3d.new(o.x, o.y, o.z)) < 0.001
    def clone = Point3d.new(x, y, z)
    def inspect = "P(#{x}, #{y}, #{z})"
  end

  class BoundingBox
    attr_reader :min, :max
    def initialize = (@min = nil; @max = nil)
    def add(*pts)
      pts.flatten.each do |p|
        p = p.respond_to?(:min) && p.is_a?(BoundingBox) ? nil : p
        next unless p
        p = Point3d.new(*p.to_a) unless p.is_a?(Point3d)
        if @min.nil?
          @min = p.clone; @max = p.clone
        else
          @min = Point3d.new([@min.x, p.x].min, [@min.y, p.y].min, [@min.z, p.z].min)
          @max = Point3d.new([@max.x, p.x].max, [@max.y, p.y].max, [@max.z, p.z].max)
        end
      end
      self
    end
    def empty? = @min.nil?
    def valid? = !@min.nil?
    def clear = (@min = nil; @max = nil; self)
    def width = empty? ? 0.0 : @max.x - @min.x
    def height = empty? ? 0.0 : @max.y - @min.y
    def depth = empty? ? 0.0 : @max.z - @min.z
    def diagonal = Math.sqrt(width**2 + height**2 + depth**2)
    def center = empty? ? Point3d.new : Point3d.new((@min.x + @max.x) / 2, (@min.y + @max.y) / 2, (@min.z + @max.z) / 2)
    def corner(i)
      Point3d.new(i & 1 == 0 ? @min.x : @max.x, i & 2 == 0 ? @min.y : @max.y, i & 4 == 0 ? @min.z : @max.z)
    end
    def contains?(p) = !empty? && p.x.between?(@min.x - 1e-9, @max.x + 1e-9) && p.y.between?(@min.y - 1e-9, @max.y + 1e-9) && p.z.between?(@min.z - 1e-9, @max.z + 1e-9)
  end

  # column-major 4x4 like SketchUp: [xx,xy,xz,0, yx,yy,yz,0, zx,zy,zz,0, ox,oy,oz,1]
  class Transformation
    attr_reader :m
    def initialize(arg = nil, *rest)
      @m = if arg.nil? then [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1].map(&:to_f)
           elsif arg.is_a?(Array) && arg.length == 16 then arg.map(&:to_f)
           elsif arg.is_a?(Transformation) then arg.m.dup
           elsif arg.is_a?(Point3d) then [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, arg.x, arg.y, arg.z, 1].map(&:to_f)
           elsif arg.is_a?(Numeric) then [arg, 0, 0, 0, 0, arg, 0, 0, 0, 0, arg, 0, 0, 0, 0, 1].map(&:to_f)
           else raise ArgumentError, "bad Transformation arg #{arg.inspect}"
           end
    end
    def self.axes(o, x, y, z) = new([x.x, x.y, x.z, 0, y.x, y.y, y.z, 0, z.x, z.y, z.z, 0, o.x, o.y, o.z, 1])
    def self.translation(v) = new([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, v.x, v.y, v.z, 1])
    def self.scaling(*a)
      if a.length == 1 then new([a[0], 0, 0, 0, 0, a[0], 0, 0, 0, 0, a[0], 0, 0, 0, 0, 1])
      elsif a.length == 3 then new([a[0], 0, 0, 0, 0, a[1], 0, 0, 0, 0, a[2], 0, 0, 0, 0, 1])
      else
        o = a[0]; sx, sy, sz = a.length == 2 ? [a[1]] * 3 : a[1, 3]
        translation(Vector3d.new(o.x, o.y, o.z)) * new([sx, 0, 0, 0, 0, sy, 0, 0, 0, 0, sz, 0, 0, 0, 0, 1]) * translation(Vector3d.new(-o.x, -o.y, -o.z))
      end
    end
    def self.rotation(o, axis, ang)
      a = axis.normalize; c = Math.cos(ang); s = Math.sin(ang); t = 1 - c
      x, y, z = a.x, a.y, a.z
      r = new([t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0,
               t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0,
               t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0, 0, 0, 0, 1])
      translation(Vector3d.new(o.x, o.y, o.z)) * r * translation(Vector3d.new(-o.x, -o.y, -o.z))
    end
    def to_a = @m.dup
    def [](i) = @m[i]
    def el(r, c) = @m[c * 4 + r]
    def *(o)
      case o
      when Transformation
        res = Array.new(16, 0.0)
        4.times { |c| 4.times { |r| res[c * 4 + r] = (0..3).sum { |k| el(r, k) * o.el(k, c) } } }
        Transformation.new(res)
      when Point3d then apply_point(o)
      when Vector3d then apply_vector(o)
      else raise ArgumentError
      end
    end
    def apply_point(p)
      w = el(3, 0) * p.x + el(3, 1) * p.y + el(3, 2) * p.z + el(3, 3)
      Point3d.new((el(0, 0) * p.x + el(0, 1) * p.y + el(0, 2) * p.z + el(0, 3)) / w,
                  (el(1, 0) * p.x + el(1, 1) * p.y + el(1, 2) * p.z + el(1, 3)) / w,
                  (el(2, 0) * p.x + el(2, 1) * p.y + el(2, 2) * p.z + el(2, 3)) / w)
    end
    def apply_vector(v)
      Vector3d.new(el(0, 0) * v.x + el(0, 1) * v.y + el(0, 2) * v.z,
                   el(1, 0) * v.x + el(1, 1) * v.y + el(1, 2) * v.z,
                   el(2, 0) * v.x + el(2, 1) * v.y + el(2, 2) * v.z)
    end
    def origin = Point3d.new(@m[12], @m[13], @m[14])
    def xaxis = Vector3d.new(@m[0], @m[1], @m[2]).normalize
    def yaxis = Vector3d.new(@m[4], @m[5], @m[6]).normalize
    def zaxis = Vector3d.new(@m[8], @m[9], @m[10]).normalize
    def identity? = @m.each_with_index.all? { |v, i| (v - (i % 5 == 0 ? 1.0 : 0.0)).abs < 1e-12 }
    def inverse
      a = (0..3).map { |r| (0..3).map { |c| el(r, c) } }
      inv = (0..3).map { |r| (0..3).map { |c| r == c ? 1.0 : 0.0 } }
      4.times do |i|
        piv = (i..3).max_by { |r| a[r][i].abs }
        raise ArgumentError, 'Matrix is not invertible' if a[piv][i].abs < 1.0e-300
        a[i], a[piv] = a[piv], a[i]; inv[i], inv[piv] = inv[piv], inv[i]
        d = a[i][i]
        4.times { |c| a[i][c] /= d; inv[i][c] /= d }
        4.times do |r|
          next if r == i
          f = a[r][i]
          4.times { |c| a[r][c] -= f * a[i][c]; inv[r][c] -= f * inv[i][c] }
        end
      end
      res = Array.new(16); 4.times { |c| 4.times { |r| res[c * 4 + r] = inv[r][c] } }
      Transformation.new(res)
    end
    def invert! = (@m = inverse.m; self)
    def clone = Transformation.new(@m)
  end
  def self.fit_plane_to_points(*) = [0, 0, 1, 0]
end

X_AXIS = Geom::Vector3d.new(1, 0, 0) unless defined?(X_AXIS)
Y_AXIS = Geom::Vector3d.new(0, 1, 0) unless defined?(Y_AXIS)
Z_AXIS = Geom::Vector3d.new(0, 0, 1) unless defined?(Z_AXIS)
ORIGIN = Geom::Point3d.new(0, 0, 0) unless defined?(ORIGIN)
IDENTITY = Geom::Transformation.new unless defined?(IDENTITY)

class Length < Float; end
class Numeric
  def mm = self / 25.4
  def inch = self.to_f
  def to_mm = self * 25.4
  def m = self / 0.0254
end

module Sketchup
  @extensions = []
  class << self
    attr_accessor :active_model, :log
    def version = '26.1.185'
    def version_number = 26_1_185
    def is_pro? = true
    def platform = :platform_win
    def os_language = 'zh-CN'
    def temp_dir = Dir.tmpdir
    def find_support_file(*) = nil
    def register_extension(*) = true
    def set_status_text(*) = true
    def status_text=(*) ; end
    def send_action(*) = true
    def active_model = @active_model
    def require(*) = true
    def undo = true
    def file_new = nil
    def open_file(*) = true
    def add_observer(*) = true
    def remove_observer(*) = true
    def plugins_disabled? = false
    def method_missing(name, *args, &blk) = nil
    def respond_to_missing?(*) = true
  end

  module AttrHost
    def attr_store = (@attr_store ||= {})
    def get_attribute(dict, key, default = nil)
      d = attr_store[dict.to_s]; return default unless d
      d.key?(key.to_s) ? d[key.to_s] : default
    end
    def set_attribute(dict, key, value) = ((attr_store[dict.to_s] ||= {})[key.to_s] = value)
    def delete_attribute(dict, key = nil)
      return !!attr_store.delete(dict.to_s) if key.nil?
      d = attr_store[dict.to_s]; d ? (d.delete(key.to_s); true) : false
    end
    def attribute_dictionary(name, create = false)
      return nil unless attr_store.key?(name.to_s) || create
      AttributeDictionary.new(name.to_s, (attr_store[name.to_s] ||= {}))
    end
    def attribute_dictionaries = AttributeDictionaries.new(attr_store)
  end

  class AttributeDictionary
    include Enumerable
    attr_reader :name
    def initialize(name, h) = (@name = name; @h = h)
    def [](k) = @h[k.to_s]
    def []=(k, v); @h[k.to_s] = v; end
    def each(&b) = @h.each(&b)
    def each_pair(&b) = @h.each(&b)
    def keys = @h.keys
    def values = @h.values
    def length = @h.length
    alias size length
    def delete_key(k) = @h.delete(k.to_s)
  end

  class AttributeDictionaries
    include Enumerable
    def initialize(store) = @store = store
    def each = @store.each { |n, h| yield AttributeDictionary.new(n, h) }
    def [](n) = @store.key?(n.to_s) ? AttributeDictionary.new(n.to_s, @store[n.to_s]) : nil
    def delete(n) = @store.delete(n.is_a?(AttributeDictionary) ? n.name : n.to_s)
    def length = @store.length
    alias size length
  end

  class Entity
    include AttrHost
    @@pid = 0
    attr_reader :persistent_id
    attr_accessor :model, :parent
    def initialize = (@@pid += 1; @persistent_id = @@pid; @valid = true)
    def valid? = @valid
    alias exists? valid?
    def deleted? = !@valid
    def erase! = (@valid = false; parent&.entities_list&.delete(self); true)
    def entityID = persistent_id
    def typename = self.class.name.split('::').last
    def add_observer(*) = true
    def remove_observer(*) = true
  end

  class Drawingelement < Entity
    attr_accessor :layer, :material, :hidden, :casts_shadows, :receives_shadows
    def initialize = (super; @hidden = false; @layer = nil; @material = nil)
    def hidden? = !!@hidden
    def visible? = !@hidden
    def visible=(v); @hidden = !v; end
    def back_material = nil
    def back_material=(*) ; end
    def casts_shadows? = true
    def receives_shadows? = true
  end

  class Vertex < Entity
    attr_reader :position
    def initialize(p) = (super(); @position = p)
  end

  class Edge < Drawingelement
    attr_reader :start, :end
    def initialize(a, b) = (super(); @start = Vertex.new(a); @end = Vertex.new(b))
    def vertices = [@start, @end]
    def bounds = Geom::BoundingBox.new.add(@start.position, @end.position)
    def soft? = false
    def smooth? = false
    def faces = []
  end

  class Face < Drawingelement
    attr_reader :pts
    def initialize(pts) = (super(); @pts = pts)
    def vertices = @pts.map { |p| Vertex.new(p) }
    def bounds = Geom::BoundingBox.new.add(*@pts)
    def normal = (a, b, c = @pts; (b - a).cross(c - a).normalize)
    def edges = []
    def area = 1.0
  end

  class Behavior
    attr_accessor :always_face_camera, :shadows_face_sun, :is2d, :cuts_opening, :snapto, :no_scale_mask
    def initialize = (@always_face_camera = false; @shadows_face_sun = false; @is2d = false; @cuts_opening = false; @snapto = 0; @no_scale_mask = 0)
    def always_face_camera? = !!@always_face_camera
    def shadows_face_sun? = !!@shadows_face_sun
    def is2d? = !!@is2d
    def cuts_opening? = !!@cuts_opening
    def no_scale_mask? = @no_scale_mask
    def scale_tool? = false
  end

  class Entities
    include Enumerable
    attr_reader :entities_list, :owner
    def initialize(owner) = (@owner = owner; @entities_list = [])
    def each(&b) = @entities_list.dup.each(&b)
    def to_a = @entities_list.dup
    def length = @entities_list.length
    alias size length
    alias count length
    def [](i) = @entities_list[i]
    def model = Sketchup.active_model
    def parent = @owner
    def <<(e) = (e.parent = self; @entities_list << e; e)
    def add_instance(definition, transform)
      transform = Geom::Transformation.new(transform) unless transform.is_a?(Geom::Transformation)
      inst = ComponentInstance.new(definition, transform)
      self << inst
      definition.instance_list << inst
      owner.touch! if owner.respond_to?(:touch!)
      inst
    end
    def add_group(*ents)
      d = Sketchup.active_model.definitions.add('Group', group: true)
      self.add_instance(d, Geom::Transformation.new).tap { |g| g.instance_variable_set(:@group, true) }
    end
    def add_edges(*pts) = pts.flatten.each_cons(2).map { |a, b| self << Edge.new(a, b) }
    def add_line(a, b) = self << Edge.new(a, b)
    def add_face(*pts) = self << Face.new(pts.flatten)
    def add_cpoint(p) = nil
    def erase_entities(*ents) = ents.flatten.each { |e| e.erase! if e.respond_to?(:erase!) }
    def clear! = @entities_list.clear
    def grep(k) = @entities_list.grep(k)
    def active_section_plane = nil
    def transform_entities(t, ents)
      Array(ents).each do |e|
        if e.is_a?(ComponentInstance) then e.transformation = t * e.transformation
        elsif e.is_a?(Edge) then e.instance_variable_set(:@start, Vertex.new(e.start.position.transform(t))); e.instance_variable_set(:@end, Vertex.new(e.end.position.transform(t)))
        elsif e.is_a?(Face) then e.instance_variable_set(:@pts, e.pts.map { |p| p.transform(t) })
        end
      end
      owner.touch! if owner.respond_to?(:touch!)
      true
    end
    def add_observer(*) = true
    def remove_observer(*) = true
    def entities_list_delete(e) = @entities_list.delete(e)
  end

  class ComponentDefinition < Entity
    attr_accessor :name, :description, :behavior, :path, :thumbnail_camera
    attr_reader :entities, :instance_list
    def initialize(name, group: false)
      super(); @name = name; @entities = Entities.new(self); @behavior = Behavior.new
      @instance_list = []; @group = group; @description = ''; @guid = SecureRandom.uuid rescue rand.to_s
    end
    def instances = @instance_list.select(&:valid?)
    def count_instances = instances.length
    def count_used_instances = instances.length
    def group? = @group
    def image? = false
    def internal? = false
    def live_component? = false
    def guid = @guid
    def touch! = nil
    def invalidate_bounds = nil
    def refresh_thumbnail = true
    def save_thumbnail(*) = false
    def insertion_point = Geom::Point3d.new
    def bounds
      box = Geom::BoundingBox.new
      @entities.each do |e|
        next unless e.valid?
        b = e.is_a?(ComponentInstance) ? e.bounds : e.bounds
        box.add(b.min, b.max) unless b.empty?
      end
      box
    end
    def save_as(path, *_)
      File.binwrite(path, "SKPFAKE #{name} #{JSON.generate(attr_store) rescue ''} #{rand}")
      true
    end
    def save_copy(path, *) = save_as(path)
    def entities_list = @entities.entities_list
  end

  class ComponentInstance < Drawingelement
    attr_accessor :name, :transformation, :locked, :glued_to
    attr_reader :definition
    def initialize(definition, transform)
      super(); @definition = definition; @transformation = transform; @name = ''; @locked = false
    end
    def definition=(d)
      @definition.instance_list.delete(self)
      @definition = d; d.instance_list << self
    end
    def transform!(t) = (@transformation = t * @transformation; true)
    def move!(t) = transform!(t)
    def locked? = !!@locked
    def group? = !!@group
    def manifold? = false
    def make_unique = (d = Sketchup.active_model.definitions.add(@definition.name + '#u'); @definition.entities.each { |e| d.entities << e.dup }; self.definition = d; self)
    def entities = @definition.entities
    def bounds
      b = @definition.bounds
      box = Geom::BoundingBox.new
      return box if b.empty?
      t = @transformation
      ang = ENV['FACEME_ROTATE'].to_f
      if ang != 0.0 && @definition.behavior.always_face_camera? && parent.is_a?(Sketchup::Entities) && parent.owner.is_a?(Sketchup::ComponentDefinition)
        o = t.origin
        t = Geom::Transformation.rotation(o, Z_AXIS, ang) * t
      end
      if ENV['FACEME_BOUNDS'] == 'disk' && @definition.behavior.always_face_camera? && parent.is_a?(Sketchup::Entities) && parent.owner.is_a?(Sketchup::ComponentDefinition)
        # 现场 SketchUp：包装里的朝向相机子组件外包盒按绕自身 Z 轴的转动范围计算。
        o = t.origin
        pts = (0..7).map { |i| b.corner(i).transform(t) }
        r = pts.map { |q| Math.hypot(q.x - o.x, q.y - o.y) }.max
        zs = pts.map(&:z)
        box.add(Geom::Point3d.new(o.x - r, o.y - r, zs.min), Geom::Point3d.new(o.x + r, o.y + r, zs.max))
        return box
      end
      8.times { |i| box.add(b.corner(i).transform(t)) }
      box
    end
    def erase!
      @valid = false
      parent.entities_list.delete(self) if parent.respond_to?(:entities_list)
      @definition.instance_list.delete(self)
      true
    end
    def explode
      ents = parent
      return false unless ents.respond_to?(:entities_list)
      t = @transformation
      created = []
      @definition.entities.to_a.each do |e|
        next unless e.valid?
        n = case e
            when ComponentInstance
              c = ents.add_instance(e.definition, t * e.transformation)
              c.name = e.name; c.material = e.material; c.layer = e.layer
              e.attr_store.each { |k, v| c.attr_store[k] = v.dup }
              c
            when Edge then ents << Edge.new(e.start.position.transform(t), e.end.position.transform(t))
            when Face then ents << Face.new(e.pts.map { |q| q.transform(t) })
            end
        created << n if n
      end
      erase!
      created
    end
    def guid = "g#{persistent_id}"
  end
  Group = Class.new(ComponentInstance) unless const_defined?(:Group)
  class Image < Drawingelement; end
  class ComponentDefinition; end
  class SectionPlane < Drawingelement; end
  class ConstructionPoint < Drawingelement; end
  class ConstructionLine < Drawingelement; end
  class Text < Drawingelement; end
  class Dimension < Drawingelement; end
  class Material < Entity; attr_accessor :name; def texture = nil; def color = nil; def alpha = 1.0; def use_alpha? = false; end
  class Layer < Entity; attr_accessor :name, :visible; def initialize(n = 'Layer0') = (super(); @name = n; @visible = true); def visible? = @visible; def display_name = @name; end
  class Camera
    attr_accessor :eye, :target, :up, :perspective, :height, :fov, :aspect_ratio
    def initialize(*a) = (@eye, @target, @up = a; @perspective = true)
    def perspective? = @perspective
    def direction = @eye.vector_to(@target).normalize
    def set(e, t, u) = (@eye, @target, @up = e, t, u; self)
  end
  class ImageRep; end
  class InputPoint; end
  class Selection
    include Enumerable
    def initialize = @items = []
    def each(&b) = @items.each(&b)
    def to_a = @items.dup
    def clear = @items.clear
    def add(*e) = (@items.concat(e.flatten); true)
    def remove(*e) = e.flatten.each { |x| @items.delete(x) }
    def length = @items.length
    alias count length
    alias size length
    def empty? = @items.empty?
    def first = @items.first
    def include?(e) = @items.include?(e)
    def contains?(e) = include?(e)
    def add_observer(*) = true
    def remove_observer(*) = true
  end

  class DefinitionList
    include Enumerable
    def initialize = @defs = []
    def each(&b) = @defs.select(&:valid?).each(&b)
    def to_a = @defs.select(&:valid?)
    def length = to_a.length
    alias size length
    alias count length
    def [](k) = k.is_a?(Integer) ? to_a[k] : to_a.find { |d| d.name == k.to_s || d.guid == k.to_s }
    def unique_name(base)
      return base unless self[base]
      i = 1; i += 1 while self["#{base}##{i}"]; "#{base}##{i}"
    end
    def add(name, group: false) = (d = ComponentDefinition.new(unique_name(name), group: group); @defs << d; d)
    def remove(d) = (d.instance_variable_set(:@valid, false); true)
    def purge_unused = true
    def load(path, *) = raise("definitions.load not simulated: #{path}")
    def add_observer(*) = true
    def remove_observer(*) = true
  end

  class RenderingOptions
    def initialize = @h = {}
    def [](k) = @h[k]
    def []=(k, v); @h[k] = v; end
    def each(&b) = @h.each(&b)
    def keys = @h.keys
  end
  class OptionsManager
    def [](k) = (@p ||= {})[k] ||= RenderingOptions.new
  end
  class View
    def camera = (@camera ||= Camera.new(Geom::Point3d.new(-1000, -1000, 1000), Geom::Point3d.new, Z_AXIS))
    def camera=(c); @camera = c.is_a?(Array) ? c.first : c; end
    def invalidate = self
    def refresh = self
    def vpwidth = 1600
    def vpheight = 900
    def write_image(*) = false
    def model = Sketchup.active_model
    def method_missing(*) = nil
    def respond_to_missing?(*) = true
  end

  class Model
    include AttrHost
    attr_reader :definitions, :entities, :selection, :ops, :active_view, :layers, :materials, :rendering_options, :options
    attr_accessor :active_path, :path, :title
    def initialize
      @definitions = DefinitionList.new; @entities = Entities.new(self); @selection = Selection.new
      @ops = []; @active_view = View.new; @layers = [Layer.new]; @materials = []; @rendering_options = RenderingOptions.new
      @options = OptionsManager.new; @active_path = nil; def @layers.add(n) = (l = Sketchup::Layer.new(n); self << l; l); def @layers.[](k) = k.is_a?(Integer) ? at(k) : find { |l| l.name == k.to_s }; @path = '/var/tmp/sim/project.skp'; @title = 'project'
      @op_depth = 0
    end
    def valid? = true
    def active_entities = @entities
    def guid = 'model-guid'
    def start_operation(name, *_) = (@ops << [:start, name]; @op_depth += 1; true)
    def commit_operation = (@ops << [:commit]; @op_depth -= 1; true)
    def abort_operation = (@ops << [:abort]; @op_depth -= 1 if @op_depth.positive?; true)
    def modified? = true
    def bounds = Geom::BoundingBox.new
    def active_layer = @layers.first
    def tags = @layers
    def pages = []
    def shadow_info = {}
    def styles = nil
    def number_faces = 0
    def save(*) = true
    def add_observer(*) = true
    def remove_observer(*) = true
    def close_active = (@active_path = nil; true)
    def touch! = nil
    def method_missing(name, *a, &b) = nil
    def respond_to_missing?(*) = true
  end
end

module UI
  class << self
    def start_timer(*_a, &_b) = 1
    def stop_timer(*) = true
    def messagebox(msg, *) = (warn "[UI.messagebox] #{msg}"; 6)
    def beep = nil
    def menu(*) = Menu.new
    def toolbar(*) = Toolbar.new
    def method_missing(*) = nil
    def respond_to_missing?(*) = true
  end
  class Menu; def initialize(*) ; end; def method_missing(*) = self; def respond_to_missing?(*) = true; end
  class Toolbar; def initialize(*) ; end; def method_missing(*) = self; def respond_to_missing?(*) = true; end
  class Command; def initialize(*) ; end; def method_missing(*) = self; def respond_to_missing?(*) = true; end
  class HtmlDialog; def initialize(*) ; end; def method_missing(*) = nil; def respond_to_missing?(*) = true; def visible? = false; end
  class Notification; def initialize(*) ; end; def method_missing(*) = nil; def respond_to_missing?(*) = true; end
  MB_YESNO = 4; MB_OK = 0; IDYES = 6; IDNO = 7; MB_YESNOCANCEL = 3; IDCANCEL = 2; MB_OKCANCEL = 1; IDOK = 1
end
MB_YESNO = 4 unless defined?(MB_YESNO)
MB_OK = 0 unless defined?(MB_OK)
IDYES = 6 unless defined?(IDYES)
IDNO = 7 unless defined?(IDNO)
IDCANCEL = 2 unless defined?(IDCANCEL)
MB_YESNOCANCEL = 3 unless defined?(MB_YESNOCANCEL)
MB_OKCANCEL = 1 unless defined?(MB_OKCANCEL)
IDOK = 1 unless defined?(IDOK)
MF_GRAYED = 1 unless defined?(MF_GRAYED)
MF_ENABLED = 0 unless defined?(MF_ENABLED)
MF_CHECKED = 8 unless defined?(MF_CHECKED)
MF_UNCHECKED = 0 unless defined?(MF_UNCHECKED)
CONSTRAIN_MODIFIER_KEY = 16 unless defined?(CONSTRAIN_MODIFIER_KEY)
COPY_MODIFIER_KEY = 4 unless defined?(COPY_MODIFIER_KEY)
ALT_MODIFIER_KEY = 32 unless defined?(ALT_MODIFIER_KEY)
VK_SHIFT = 16 unless defined?(VK_SHIFT)
VK_CONTROL = 17 unless defined?(VK_CONTROL)
VK_ALT = 18 unless defined?(VK_ALT)
VK_ESCAPE = 27 unless defined?(VK_ESCAPE)
VK_DELETE = 46 unless defined?(VK_DELETE)
VK_UP = 38 unless defined?(VK_UP)
VK_DOWN = 40 unless defined?(VK_DOWN)
VK_LEFT = 37 unless defined?(VK_LEFT)
VK_RIGHT = 39 unless defined?(VK_RIGHT)
VK_COMMAND = 0 unless defined?(VK_COMMAND)
VK_MENU = 18 unless defined?(VK_MENU)
module Sketchup; module Http; end; class ModelObserver; end; class EntitiesObserver; end; class SelectionObserver; end; class AppObserver; end; class DefinitionsObserver; end; class DefinitionObserver; end; class EntityObserver; end; class ViewObserver; end; class ToolsObserver; end; class InstanceObserver; end; class FrameChangeObserver; end; class LayersObserver; end; class PagesObserver; end; class RenderingOptionsObserver; end; class MaterialsObserver; end; class ShadowInfoObserver; end; class OptionsProviderObserver; end; class Extension; def initialize(*) ; end; def method_missing(*) = self; def respond_to_missing?(*) = true; end; end
class SketchupExtension; def initialize(*) ; end; def method_missing(*) = self; def respond_to_missing?(*) = true; end
def file_loaded?(*) = false
def file_loaded(*) = true
module Sketchup
  class Overlay
    def initialize(*) ; end
    def method_missing(*) = nil
    def respond_to_missing?(*) = true
  end
  class Tool; end
end
SB_PROMPT = 0 unless defined?(SB_PROMPT); SB_VCB_LABEL = 1 unless defined?(SB_VCB_LABEL); SB_VCB_VALUE = 2 unless defined?(SB_VCB_VALUE)
