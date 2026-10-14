# frozen_string_literal: true
# 用法：ruby tests/flat_card_ingest_scale_test.rb <runtime.rb 路径>
# 从 runtime.rb 中取出 soft_instance_scale_only_transformation 与 soft_face_camera_dimensions_mm，
# 在替身环境中验证：零厚度片状组件（卡片人）可以算出有效、可逆的入库缩放；
# 朝向相机组件清单长宽一致取最大值。
runtime = ARGV[0] or abort 'usage: flat_card_ingest_scale_test.rb <runtime.rb>'
source = File.read(runtime, encoding: 'utf-8')

def extract_method(source, name)
  start = source.index(/^    def #{Regexp.escape(name)}\b/) or raise "method #{name} not found"
  finish = source.index(/^    end\n/, start) or raise "end of #{name} not found"
  source[start...(finish + 8)]
end

module Geom
  class Point3d
    attr_reader :x, :y, :z
    def initialize(x, y, z) = (@x, @y, @z = x.to_f, y.to_f, z.to_f)
  end
  class Vector3d
    attr_reader :x, :y, :z
    def initialize(x, y, z) = (@x, @y, @z = x.to_f, y.to_f, z.to_f)
    def cross(o) = Vector3d.new(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    def dot(o) = x * o.x + y * o.y + z * o.z
  end
  class Transformation
    attr_reader :values
    def initialize(values = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]) = @values = values.map(&:to_f)
    def to_a = @values
    def *(other) = self
  end
end

class FakeBehavior
  def initialize(face) = @face = face
  def always_face_camera? = @face
end
class FakeBounds
  attr_reader :width, :height, :depth
  def initialize(w, h, d) = (@width, @height, @depth = w, h, d)
end
class FakeDefinition
  attr_reader :extents, :behavior
  def initialize(extents, face: false) = (@extents, @behavior = extents, FakeBehavior.new(face))
  def valid? = true
  def bounds = FakeBounds.new(*@extents)
  def entities = []
end
class FakeInstance
  attr_reader :definition
  def initialize(definition) = @definition = definition
  def valid? = true
end

class Harness
  SOFT_PLANAR_REFERENCE_EPSILON_MM = 0.05
  attr_reader :logs
  def initialize = @logs = []
  def log(msg) = @logs << msg
  def log_exception(label, e) = @logs << "#{label}: #{e.message}"
  def absolute_transformation_for_selected_entity(*) = Geom::Transformation.new
  def soft_transform_basis_vectors(_t) = [Geom::Vector3d.new(1, 0, 0), Geom::Vector3d.new(0, 1, 0), Geom::Vector3d.new(0, 0, 1)]
  def soft_fresh_definition_axis_extents(definition) = definition.extents
  def soft_library_actual_axis_dimensions_mm(instance, *_args, **_kw) = instance.definition.extents.map { |v| v * 25.4 }
  def soft_exact_axes_transformation(_origin, x, y, z) = [x.x, y.y, z.z]
  def soft_definition_face_camera?(definition) = definition.behavior.always_face_camera?
end
Harness.class_eval(extract_method(source, 'soft_instance_scale_only_transformation'))
Harness.class_eval(extract_method(source, 'soft_face_camera_dimensions_mm'))

failures = []
h = Harness.new

# 卡片人：宽 600mm、厚 0、高 1700mm（XZ 平面，Y 为 0）。
card = FakeInstance.new(FakeDefinition.new([600 / 25.4, 0.0, 1700 / 25.4], face: true))
begin
  scales = h.soft_instance_scale_only_transformation(card, nil, desired_mm: [600.0, 0.0, 1700.0])
  ok = scales.all? { |s| s.finite? && s > 1.0e-9 } && (scales[0] - 1).abs < 1e-9 && (scales[2] - 1).abs < 1e-9 && (scales[1] - 1).abs < 1e-9
  puts "card scales: #{scales.inspect}"
  failures << "card scales invalid #{scales.inspect}" unless ok
rescue StandardError => e
  failures << "card raised: #{e.message}"
end

# 缩放过的卡片：X×2、Z×2，零厚度轴取平均比例 2，矩阵可逆。
begin
  scales = h.soft_instance_scale_only_transformation(card, nil, desired_mm: [1200.0, 0.0, 3400.0])
  puts "scaled card scales: #{scales.inspect}"
  failures << "scaled card #{scales.inspect}" unless scales.map { |s| s.round(9) } == [2.0, 2.0, 2.0]
rescue StandardError => e
  failures << "scaled card raised: #{e.message}"
end

# 线或空组件仍然拒绝。
line = FakeInstance.new(FakeDefinition.new([10.0, 0.0, 0.0]))
begin
  h.soft_instance_scale_only_transformation(line, nil, desired_mm: [254.0, 0.0, 0.0])
  failures << 'line accepted'
rescue StandardError
  puts 'line rejected: ok'
end

# 普通家具不受影响。
box = FakeInstance.new(FakeDefinition.new([10.0, 20.0, 30.0]))
scales = h.soft_instance_scale_only_transformation(box, nil, desired_mm: [254.0, 1016.0, 762.0])
failures << "box #{scales.inspect}" unless scales.map { |s| s.round(9) } == [1.0, 2.0, 1.0]

# 朝向相机：清单长宽一致取最大值。
dims = h.soft_face_camera_dimensions_mm(card, Geom::Transformation.new)
puts "face camera dims: #{dims.inspect}"
failures << "face camera dims #{dims.inspect}" unless dims == [600.0, 600.0, 1700.0]

if failures.empty?
  puts 'PASS'
else
  puts "FAIL: #{failures.join('; ')}"
  exit 1
end
