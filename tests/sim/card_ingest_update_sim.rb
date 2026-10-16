# 模拟 SketchUp 运行插件真实代码：卡片/盒子直接入库后再连续更新 3 次，打印结果、嵌套层数和库资料尺寸。
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'securerandom'
require 'tmpdir'
require 'sketchup'
SRC = ARGV[0] or abort('usage: ruby tests/sim/card_ingest_update_sim.rb <su_linkhub dir> [space_x] [space_y] [case]')
TMP = Dir.mktmpdir('lhsim')
ENV['TEMP'] = File.join(TMP, 'temp'); FileUtils.mkdir_p ENV['TEMP']
LIB = File.join(TMP, 'library'); FileUtils.mkdir_p LIB
model = Sketchup::Model.new
Sketchup.active_model = model
$stdout.sync = true
Kernel.load(File.join(SRC, 'main.rb'))
RT = GavinTools::SULinkHubMultiSpace::Runtime
LOGS = []
RT.define_singleton_method(:log) { |msg, *_| LOGS << msg.to_s }
RT.define_singleton_method(:log_exception) { |label, e, *_| LOGS << "EXC #{label}: #{e.class}: #{e.message} @ #{Array(e.backtrace).first(3).join(' | ')}" }
RT.define_singleton_method(:soft_library_root) { LIB }

def rect_def(model, name, w_in, t_in, h_in, face_camera:, x0: 0.0, y0: 0.0, z0: 0.0)
  d = model.definitions.add(name)
  d.behavior.always_face_camera = face_camera
  d.behavior.shadows_face_sun = face_camera
  pts = if t_in.zero? || face_camera
          [[x0, y0, z0], [x0 + w_in, y0 + t_in, z0], [x0 + w_in, y0 + t_in, z0 + h_in], [x0, y0, z0 + h_in]]
        else
          [[x0, y0, z0], [x0 + w_in, y0, z0], [x0 + w_in, y0 + t_in, z0], [x0, y0 + t_in, z0],
           [x0, y0, z0 + h_in], [x0 + w_in, y0, z0 + h_in], [x0 + w_in, y0 + t_in, z0 + h_in], [x0, y0 + t_in, z0 + h_in]]
        end.map { |p| Geom::Point3d.new(*p) }
  pts.each_with_index { |p, i| d.entities.add_line(p, pts[(i + 1) % pts.length]) }
  d.entities.add_face(*pts.first(4))
  d
end

# space
space_def = model.definitions.add('空间A')
space = model.entities.add_instance(space_def, Geom::Transformation.translation(Geom::Vector3d.new(ARGV[1].to_f, ARGV[2].to_f, 0)))
space.set_attribute(RT::ENTITY_DICT, 'space_id', 'S1')
space.set_attribute(RT::ENTITY_DICT, 'kind', 'space_model')
STATE = { 'space_models' => [{ 'id' => 'S1', 'name' => '空间A' }], 'space_editing_id' => '', 'space_display_mode' => 'full' }
RT.define_singleton_method(:load_state) { |*_| STATE }
RT.define_singleton_method(:save_state) { |*_a, **_k| true }
RT.define_singleton_method(:ensure_space_models_ready!) { |*_| STATE }
RT.define_singleton_method(:space_model_entity) { |id, *_| id.to_s == 'S1' ? space : nil }

cases = {
  # basket: real bounds from 单独脏衣篮.skp (inches)
  'basket' => [121.91779183 / 25.4, 3.069544618483633e-12, 486.19433333 / 25.4, true, -57.966931 / 25.4, -3.410605131648481e-13, -41.887512 / 25.4],
  'sree' => [630.73809505 / 25.4, 0.0, 1593.45438955 / 25.4, true, 0, 0, 0],
  'box' => [20.0, 15.0, 30.0, false, 0, 0, 0]
}
only = ARGV[3]
results = {}
cases.each do |key, (w, t, h, fc, x0, y0, z0)|
  next if only && only != key
  LOGS.clear
  d = rect_def(model, "def_#{key}", w, t, h, face_camera: fc, x0: x0, y0: y0, z0: z0)
  rot = Geom::Transformation.rotation(Geom::Point3d.new, Z_AXIS, fc ? 0.83 : 0.0)
  inst = space_def.entities.add_instance(d, Geom::Transformation.translation(Geom::Vector3d.new(100, 50, 0)) * rot)
  inst.name = "软装-摆件-收纳（#{key}）"
  # captured inside space (prepare_soft_pending_ingest_candidates! style)
  captured = RT.soft_library_actual_axis_dimensions_mm(inst, model, combined_transform: space.transformation * inst.transformation)
  begin
    res = RT.ingest_tagged_furniture_entity_into_library!(inst, category: '摆件', subcategory: '收纳', requested_name: key, model: model,
                                                          ingest_state: STATE, batch_mode: true, expected_axis_mm: captured)
    results[key] = "OK planar=#{res[:planar_reference]} adopted=#{res[:adopted_count]} repr=#{res[:representation]}"
    w2 = res[:source_definition]
    results[key] += " lib_mm=#{RT.soft_definition_axis_extents(w2).map { |v| (v * 25.4).round(3) }}" if w2
    results[key] += " inst_def=#{inst.definition.name}"
    begin
      captured2 = RT.soft_library_actual_axis_dimensions_mm(inst, model, combined_transform: space.transformation * inst.transformation)
      up = nil; depths = []; 3.times { up = RT.update_existing_soft_library_from_entity!(inst, model_id: res[:model_id], source_path: res[:target], model_name: res[:model_name], model: model, expected_axis_mm: captured2); d = inst.definition; n = 0; while d && d.entities.to_a.length == 1 && d.entities.first.respond_to?(:definition); n += 1; d = d.entities.first.definition; end; depths << n }; results[key] += " nest=#{depths}"
      results[key] += "\n   UPDATE OK planar=#{up[:planar_reference]} lib_mm=#{RT.soft_definition_axis_extents(inst.definition).map { |v| (v * 25.4).round(3) }} depth=#{RT.soft_linkhub_pure_wrapper_chain_depth(inst.definition) rescue '?'}"
      meta = JSON.parse(File.read(RT.soft_model_sidecar_path(res[:target]))) rescue {}
      results[key] += " meta_lwh=#{[meta['length_mm'], meta['width_mm'], meta['height_mm']]} axis=#{meta['ingested_actual_axis_mm']}"
    rescue StandardError => e
      results[key] += "\n   UPDATE FAIL #{e.class}: #{e.message}\n    #{e.backtrace.first(5).join("\n    ")}"
    end
  rescue StandardError => e
    results[key] = "FAIL #{e.class}: #{e.message}\n    #{e.backtrace.first(6).join("\n    ")}"
  end
  puts "== #{key}: captured=#{captured.map { |v| v.round(6) }}"
  puts "   #{results[key]}"
  LOGS.each { |l| puts "   log: #{l[0, 300]}" if l =~ /EXC|失败|片状|朝向|尺寸|不可逆/ }
end
