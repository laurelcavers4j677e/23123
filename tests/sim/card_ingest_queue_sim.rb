# frozen_string_literal: true
# 在 Linux 上用模拟的 SketchUp API（tests/sim/lib/sketchup.rb）运行插件真实代码，
# 跑完整的家具入库队列：空间内登记 -> 退出空间 -> 逐件写库 -> 接管实例。
# 样例：单独脏衣篮.skp 的真实组件尺寸、Sree 卡片人（严格 0 厚度）、普通盒子。
# 环境变量 FACEME_ROTATE=<弧度> 模拟 SketchUp 把包装内的朝向相机子组件转向镜头。
# 用法：FACEME_ROTATE=0.96 ruby tests/sim/card_ingest_queue_sim.rb <su_linkhub 目录>
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'securerandom'
require 'tmpdir'
require 'sketchup'
SRC = ARGV[0] or abort('usage: ruby tests/sim/card_ingest_queue_sim.rb <su_linkhub dir> [space_x] [space_y]')
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
  'basket' => [121.91779183 / 25.4, 3.069544618483633e-12, 486.19433333 / 25.4, true, -57.966931 / 25.4, -3.410605131648481e-13, -41.887512 / 25.4],
  'sree' => [630.73809505 / 25.4, 0.0, 1593.45438955 / 25.4, true, 0, 0, 0],
  'box' => [20.0, 15.0, 30.0, false, 0, 0, 0],
  # 现场日志：实例按 2.570313 放大后入库（目标 485.31 × 0 × 563.99mm）。
  'basket_scaled' => [121.91779183 / 25.4, 3.069544618483633e-12, 486.19433333 / 25.4, true, -57.966931 / 25.4, -3.410605131648481e-13, -41.887512 / 25.4]
}
SCALE = { 'basket_scaled' => Geom::Transformation.scaling(Geom::Point3d.new, 2.570313, 2.570313, 1.16) }
item = { 'id' => 'S1', 'number' => '1', 'name' => '空间A', 'editing' => true }
STATE['space_models'] = [item]
RT.define_singleton_method(:space_model_record) { |_s, id| id.to_s == 'S1' ? item : nil }
model.active_path = [space]
candidates = []
insts = {}
cases.each do |key, (w, t, h, fc, x0, y0, z0)|
  d = rect_def(model, "def_#{key}", w, t, h, face_camera: fc, x0: x0, y0: y0, z0: z0)
  rot = Geom::Transformation.rotation(Geom::Point3d.new, Z_AXIS, fc ? 0.83 : 0.0)
  inst = space_def.entities.add_instance(d, Geom::Transformation.translation(Geom::Vector3d.new(100, 50, 0)) * rot * (SCALE[key] || Geom::Transformation.new))
  inst.name = "软装-摆件-收纳（#{key}）"
  insts[key] = inst
  candidates << { action: :new, entity: inst, definition: d, category: '摆件', subcategory: '收纳', requested_name: key,
                  marker_count: 1, marked_entities: [inst], draft_ui: true }
end
RT.start_soft_batch_ingest_candidates_job!(candidates, model, item, LIB)
job = RT.instance_variable_get(:@soft_ingest_batch_job)
puts "captured: " + job[:queue].map { |c| "#{c[:requested_name]}=#{Array(c[:captured_axis_mm]).map { |v| v.round(4) }}" }.join(' ')
model.active_path = nil
job[:waiting_workspace_exit] = false
job[:index] = RT.read_soft_library_index(LIB)
20.times do
  break unless RT.instance_variable_get(:@soft_ingest_batch_job)
  RT.process_soft_tagged_furniture_ingest_job_at_root
end
puts "job left: #{!RT.instance_variable_get(:@soft_ingest_batch_job).nil?}"
puts "success=#{job[:success]} failed=#{job[:failed]}"
job[:errors].each { |e| puts "  ERR #{e[:name]}: #{e[:message]}" }
insts.each { |k, i| puts "  #{k}: def=#{i.definition.name} planar=#{RT.soft_instance_planar_reference?(i)} name=#{i.name}" }
Dir.glob(File.join(LIB, '**', '*.json')).each { |f| next unless f =~ /摆件/; m = JSON.parse(File.read(f)) rescue next; puts "  meta #{File.basename(f)} lwh=#{[m['length_mm'], m['width_mm'], m['height_mm']]} axis=#{m['ingested_actual_axis_mm']} planar=#{m['planar_reference']}" }
LOGS.each { |l| puts "  log: #{l[0, 260]}" if l =~ /家具入库失败/ }
metas = Dir.glob(File.join(LIB, '**', '*.soft.json')).to_h { |f| [File.basename(f).split('.').first, (JSON.parse(File.read(f)) rescue {})] }
ok = job[:failed].zero? && job[:success] == cases.length &&
     metas['basket'].to_h['ingested_actual_axis_mm'].to_a.map { |v| v.round(1) } == [121.9, 0.0, 486.2] &&
     metas['sree'].to_h['ingested_actual_axis_mm'].to_a.map { |v| v.round(1) } == [630.7, 0.0, 1593.5] &&
     metas['basket_scaled'].to_h['ingested_actual_axis_mm'].to_a.map { |v| v.round(1) } == [313.4, 0.0, 564.0]
puts ok ? 'PASS' : 'FAIL'
FileUtils.rm_rf(TMP)
exit(ok ? 0 : 1)
