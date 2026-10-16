# frozen_string_literal: true
# 模拟 SketchUp 运行插件真实代码，检查 v0.13.7.15 的“家具更新”统一任务：
# 6 张六面代理视图 + 2 张轴测缩略图 = 8 张，一个任务一条总进度；以及缩略图按源签名判断是否最新、
# 改轴指纹、结构审计签名。
# 用法：ruby tests/sim/update_pipeline_sim.rb <su_linkhub 目录>
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'securerandom'
require 'tmpdir'
require 'sketchup'
SRC = ARGV[0] or abort('usage: ruby tests/sim/update_pipeline_sim.rb <su_linkhub dir>')
TMP = Dir.mktmpdir('lhpipe')
ENV['TEMP'] = File.join(TMP, 'temp'); FileUtils.mkdir_p ENV['TEMP']
LIB = File.join(TMP, 'library'); FileUtils.mkdir_p LIB
model = Sketchup::Model.new
Sketchup.active_model = model
Kernel.load(File.join(SRC, 'main.rb'))
RT = GavinTools::SULinkHubMultiSpace::Runtime
LOGS = []
RT.define_singleton_method(:log) { |m, *_| LOGS << m.to_s }
RT.define_singleton_method(:log_exception) { |l, e, *_| LOGS << "EXC #{l}: #{e.message}" }
RT.define_singleton_method(:soft_library_root) { LIB }
failures = []
check = ->(cond, msg) { failures << msg unless cond }

# ---------- 1. 统一任务进度 ----------
source = File.join(LIB, 'chair.skp'); File.write(source, 'v1')
item = { 'id' => 'M1', 'name' => '椅子', 'path' => source }
RT.define_singleton_method(:soft_thumbnail_view_item) { |_id| item }
rendered = []
RT.define_singleton_method(:render_soft_thumbnail_view!) do |_m, src, view, root = nil, local_stage: false|
  rendered << view
  [false, true].each { |hd| f = soft_thumbnail_view_path(src, view, root || LIB, hd: hd); FileUtils.mkdir_p(File.dirname(f)); File.write(f, 'png') }
  write_soft_thumbnail_view_signature!(fast_file_signature(src), soft_thumbnail_view_path(src, view, root || LIB), soft_thumbnail_view_path(src, view, root || LIB, hd: true))
  { view: view, face_camera: false }
end
RT.define_singleton_method(:soft_thumbnail_view_content_valid?) { |_p| true }
RT.define_singleton_method(:apply_soft_thumbnail_preferred_view!) { |*_a, **_k| true }
RT.define_singleton_method(:send_soft_thumbnail_view_update!) { |*_a| true }
RT.define_singleton_method(:soft_visual_proxy_queue_ready?) { |*_a, **_k| [true, '', 0] }
RT.define_singleton_method(:verify_soft_proxy_requested_display!) { |*_a| true }
RT.define_singleton_method(:complete_soft_pending_proxy_rebuilds_for_model!) { |*_a| 1 }
notices = []
RT.define_singleton_method(:show_workspace_floating_notice) { |msg, *_a, **k| notices << [msg, k[:progress]] }

task = RT.start_soft_furniture_update_task!('椅子')
seed = { model_id: 'M1', model_name: '椅子', proxy_task_id: task }
# 六面阶段内部汇报 48%（截图结束）→ 总进度应换算成 36%
RT.update_task_center_job!(task, progress: 48, stage: '视图 6/8 · 六面', status: 'running')
p1 = RT.task_center_job_snapshot(task)[:progress]
check.call(p1 == 36, "proxy stage scaled progress expected 36, got #{p1}")
job = { model: model, success: 0, replaced: 0, completed: [], done: 0, errors: [] }
RT.finish_soft_visual_proxy_candidate_success!(job, seed, { replaced: 1 }, task_id: task)
snap = RT.task_center_job_snapshot(task)
check.call(snap[:status] == 'running' && snap[:progress] == 75, "after proxy: expected running/75, got #{snap[:status]}/#{snap[:progress]}")
q = RT.instance_variable_get(:@soft_thumbnail_view_queue)
check.call(q && q.first && q.first[:pipeline_task_id] == task, 'thumbnail job not attached to the same task')
progress_seen = []
5.times do
  break if RT.instance_variable_get(:@soft_thumbnail_view_queue).empty?
  RT.process_soft_thumbnail_view_queue_tick!
  progress_seen << RT.task_center_job_snapshot(task)[:progress]
end
snap = RT.task_center_job_snapshot(task)
check.call(rendered == %w[a b], "rendered views #{rendered.inspect}")
check.call(snap[:status] == 'completed' && snap[:stage_label].include?('8/8'), "final task #{snap[:status]} #{snap[:stage_label]}")
check.call(progress_seen.include?(88) || progress_seen.include?(87), "no 7/8 progress step: #{progress_seen.inspect}")
check.call(notices.any? { |m, _| m.include?('家具更新完成') }, 'no final notice')
puts "task progress: #{p1} -> 75 -> #{progress_seen.inspect} status=#{snap[:status]} stage=#{snap[:stage_label]}"

# ---------- 2. 缩略图按源签名判断 ----------
check.call(RT.soft_thumbnail_view_current?(source, 'a', LIB), 'fresh view not current')
mtime = File.mtime(source)
File.write(source, 'v2-changed-geometry')
File.utime(mtime, mtime, source) # 同一修改时间（模拟 NAS 粗时间精度）
sidecar = RT.soft_thumbnail_view_signature_path(RT.soft_thumbnail_view_path(source, 'a', LIB))
check.call(!RT.soft_thumbnail_view_current?(source, 'a', LIB), 'stale view accepted after source rewrite with same mtime (size changed)')
puts "view freshness: sidecar=#{File.basename(sidecar)} stale-detected=#{!RT.soft_thumbnail_view_current?(source, 'a', LIB)}"

# 同大小、同修改时间的改写（NAS 粗时间精度）：本机写库会删除源签名记录，旧视图不再算最新。
RT.instance_variable_set(:@soft_thumbnail_view_queue, [])
rendered.clear
RT.enqueue_soft_thumbnail_views!('M1', reason: '用户刷新', immediate: true, force: true)
3.times { RT.process_soft_thumbnail_view_queue_tick! }
check.call(RT.soft_thumbnail_view_current?(source, 'a', LIB), 're-rendered view not current')
mtime = File.mtime(source)
size = File.size(source)
File.write(source, 'x' * size)
File.utime(mtime, mtime, source)
check.call(RT.soft_thumbnail_view_current?(source, 'a', LIB), 'precondition: same-size same-mtime rewrite is invisible to the file signature')
rev_before = RT.soft_library_source_revision(source)
RT.note_soft_library_source_rewritten!(source, LIB)
check.call(!RT.soft_thumbnail_view_current?(source, 'a', LIB), 'same-size same-mtime rewrite: stale view still accepted')
check.call(RT.soft_library_source_revision(source) == rev_before + 1, 'source revision not bumped')
puts "same-size rewrite: stale-detected=#{!RT.soft_thumbnail_view_current?(source, 'a', LIB)} revision=#{RT.soft_library_source_revision(source)}"

# 热重载：进入轴测阶段的任务不会永远停在 75–88%。
t2 = RT.start_soft_furniture_update_task!('沙发')
RT.update_task_center_job!(t2, progress: 75, stage: '六面完成', status: 'running', raw: true)
RT.instance_variable_set(:@soft_thumbnail_view_queue, [{ id: 'M1', pipeline_task_id: t2, done: ['a'], attempts: 0 }])
RT.recover_soft_thumbnail_pipeline_after_reload!
snap2 = RT.task_center_job_snapshot(t2)
check.call(snap2[:status] == 'failed' && RT.instance_variable_get(:@soft_thumbnail_view_queue).first[:pipeline_task_id].to_s.empty?, "reload recovery: #{snap2[:status]}")
RT.instance_variable_set(:@soft_thumbnail_view_queue, [])

# 轴测阶段排不进队列时，不能把统一任务报成成功。
t3 = RT.start_soft_furniture_update_task!('桌子')
RT.define_singleton_method(:ensure_soft_thumbnail_view_driver!) { false }
job3 = { model: model, success: 0, replaced: 0, completed: [], done: 0, errors: [] }
RT.finish_soft_visual_proxy_candidate_success!(job3, { model_id: 'M1', model_name: '桌子', proxy_task_id: t3 }, { replaced: 0 }, task_id: t3)
snap3 = RT.task_center_job_snapshot(t3)
check.call(snap3[:status] == 'failed' && snap3[:stage_label].include?('未启动'), "enqueue failure reported as #{snap3[:status]} #{snap3[:stage_label]}")
RT.singleton_class.send(:remove_method, :ensure_soft_thumbnail_view_driver!)
RT.instance_variable_set(:@soft_thumbnail_view_queue, [])

# ---------- 3. 自动视图等待同款代理 ----------
RT.instance_variable_set(:@soft_thumbnail_view_queue, [])
rendered.clear
RT.instance_variable_set(:@soft_visual_proxy_upgrade_job, { scan_queue: [{ model_id: 'M1' }], queue: [] })
RT.enqueue_soft_thumbnail_views!('M1', reason: '入库/更新')
RT.define_singleton_method(:runtime_interaction_age) { |*_| 99 }
RT.process_soft_thumbnail_view_queue_tick!
check.call(rendered.empty?, 'automatic thumbnail rendered before proxy finished')
RT.instance_variable_set(:@soft_visual_proxy_upgrade_job, nil)
RT.instance_variable_set(:@soft_thumbnail_view_queue, [])

# ---------- 4. 改轴指纹 ----------
d = model.definitions.add('家具')
d.entities.add_face(Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(10, 0, 0), Geom::Point3d.new(10, 0, 10), Geom::Point3d.new(0, 0, 10))
inst = model.entities.add_instance(d, Geom::Transformation.new)
fp1 = RT.soft_individual_edit_quick_fingerprint(inst)
d.entities.transform_entities(Geom::Transformation.translation(Geom::Vector3d.new(-5, 0, 0)), d.entities.to_a)
inst.transformation = Geom::Transformation.translation(Geom::Vector3d.new(5, 0, 0))
fp2 = RT.soft_individual_edit_quick_fingerprint(inst)
check.call(!fp1.empty? && fp1 != fp2, 'axis change not detected by fingerprint')
record = { change_tracking: 'transaction', content_changed: false, quick_fingerprint_before: fp1, entity: inst, model_name: '家具' }
check.call(RT.soft_individual_edit_content_unchanged?(record) == false, 'unchanged? should be false after axis change')
record2 = { change_tracking: 'transaction', content_changed: false, quick_fingerprint_before: fp2, entity: inst, model_name: '家具' }
check.call(RT.soft_individual_edit_content_unchanged?(record2) == true, 'unchanged? should be true without change')

# ---------- 5. 结构审计签名 ----------
s1 = RT.edit_structure_guard_signature(model)
s1b = RT.edit_structure_guard_signature(model)
d2 = model.definitions.add('空间')
sp = model.entities.add_instance(d2, Geom::Transformation.new)
sp.set_attribute(RT::ENTITY_DICT, 'managed', true)
s2 = RT.edit_structure_guard_signature(model)
sp.erase!
s3 = RT.edit_structure_guard_signature(model)
check.call(s1 == s1b && s1 != s2 && s2 != s3, 'structure guard signature does not track root changes')

# ---------- 6. 零厚度替换不再产生近零缩放 ----------
card = model.definitions.add('卡片')
card.entities.add_face(Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(20, 0, 0), Geom::Point3d.new(20, 0, 60), Geom::Point3d.new(0, 0, 60))
box = model.definitions.add('盒子')
box.entities.add_line(Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(10, 5, 30))
snapshot = { dimensions: [20.0, 0.0, 60.0], basis: [X_AXIS, Y_AXIS, Z_AXIS], bottom_center: Geom::Point3d.new(10, 0, 0) }
t = RT.soft_transformation_from_box_snapshot(snapshot, box)
ys = Geom::Vector3d.new(t.to_a[4], t.to_a[5], t.to_a[6]).length
check.call(ys > 0.1, "flat replacement Y scale too small: #{ys}")
puts "flat->box replacement scales: #{[t.to_a[0], ys, t.to_a[10]].map { |v| v.round(3) }}"

LOGS.grep(/EXC/).first(5).each { |l| puts "  #{l}" }
FileUtils.rm_rf(TMP)
if failures.empty?
  puts 'PASS'
else
  puts "FAIL: #{failures.join('; ')}"
  exit 1
end
