# frozen_string_literal: true
# 模拟 SketchUp 运行插件真实代码，检查 v0.13.7.16 的界面逻辑：
# 联动空间自动归组与组内排序、空间组默认展开、提醒类按钮常显示、隐藏卡片判定、待载入联动空间状态文字。
# 用法：ruby tests/sim/drawer_ui_sim.rb <su_linkhub 目录>
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'securerandom'
require 'tmpdir'
require 'sketchup'
SRC = ARGV[0] or abort('usage: ruby tests/sim/drawer_ui_sim.rb <su_linkhub dir>')
TMP = Dir.mktmpdir('lhui')
ENV['TEMP'] = File.join(TMP, 'temp'); FileUtils.mkdir_p ENV['TEMP']
model = Sketchup::Model.new
Sketchup.active_model = model
Kernel.load(File.join(SRC, 'main.rb'))
RT = GavinTools::SULinkHubMultiSpace::Runtime
LOGS = []
RT.define_singleton_method(:log) { |m, *_| LOGS << m.to_s }
failures = []
check = ->(cond, msg) { failures << msg unless cond }

# 楼层识别
{ '三层标间1' => '3F', '3F' => '3F', '二层茶室' => '2F', '12楼大堂' => '12F', 'B1车库' => 'B1', '顶层公区' => '顶层', '泳池露台' => '' }.each do |text, want|
  got = RT.space_name_floor_key(text)
  check.call(got == want, "floor #{text}: #{got} != #{want}")
end

soft = RT::SOFT_SPACE_COLLECTION_KEY
state = {
  'space_groups' => [{ 'id' => 'g2', 'name' => '2F', 'order' => 0 }, { 'id' => 'g3', 'name' => '3F', 'order' => 1 }, { 'id' => 'gp', 'name' => '公区', 'order' => 2 }],
  'space_models' => [
    ['s1', '二层标间1', 'g2', 0], ['s2', '二层标间2', 'g2', 1], ['s3', '二层茶室', 'g2', 2],
    ['s4', '三层标间1', 'g3', 0], ['s5', '三层标间2', 'g3', 1], ['s6', '三层标间4', 'g3', 2], ['s7', '三层过道', 'g3', 3],
    ['s8', '泳池露台', 'gp', 0], ['s9', '瑜伽室公区', 'gp', 1]
  ].map { |id, name, gid, order| { 'id' => id, 'name' => name, 'group_id' => gid, 'group_order' => order, 'number' => order + 1, 'collection_key' => soft } }
}
# 顶层公区与现有各组都不够像（得分 < 1.5），沿用来源空间的组（这里是 2F）。
cases = { '三层标间3' => 'g3', '三层大客房' => 'g3', '二层标间5' => 'g2', '顶层公区' => 'g2', '健身房' => 'g2' }
cases.each do |name, want|
  got = RT.best_linked_space_group_id(state, name, soft, 'g2')
  check.call(got == want, "group for #{name}: #{got} != #{want}")
end
puts LOGS.grep(/自动归组/).first(5)

item = { 'id' => 'new', 'name' => '三层标间3', 'group_id' => 'g3', 'number' => 30, 'collection_key' => soft }
changed = RT.insert_space_into_group_by_name!(state, item)
state['space_models'] << item
order = state['space_models'].select { |s| s['group_id'] == 'g3' }.sort_by { |s| s['group_order'] }.map { |s| s['name'] }
check.call(order == %w[三层标间1 三层标间2 三层标间3 三层标间4 三层过道], "group order #{order}")
check.call(changed.sort == %w[s6 s7], "changed ids #{changed}")
puts "3F order: #{order.join(' > ')}"

# 空间组默认展开（一次性迁移）
st = { 'space_groups' => [{ 'id' => 'g', 'name' => '3F', 'order' => 0, 'collapsed' => true }], 'space_models' => [], 'architecture_groups' => [{ 'id' => 'a', 'name' => 'A', 'collapsed' => true }] }
begin
  RT.normalize_space_models_state!(st, model)
rescue StandardError => e
  puts "normalize raised: #{e.message}"
end
check.call(st['space_groups'].first['collapsed'] == false, 'space group not expanded by default')
check.call(st['architecture_groups'].first['collapsed'] == false, 'architecture group not expanded by default')
st['space_groups'].first['collapsed'] = true
RT.normalize_space_models_state!(st, model) rescue nil
check.call(st['space_groups'].first['collapsed'] == true, 'user collapse choice overwritten after migration')

# 工具条与卡片规则（这些方法在类里是 private，用 send 调用）
ov = RT::WorkspaceToolbarOverlay.allocate
ov.instance_variable_set(:@state, {})
check.call(ov.send(:mode_switch_progress) == 1.0 && ov.send(:drawer_mode_switch_progress) == 1.0, 'toolbar groups not expanded')
check.call(ov.send(:drawer_row_attention?, { 'action' => 'drawer_space_update:1', 'action_label' => '载入' }), 'load not attention')
check.call(ov.send(:drawer_row_attention?, { 'action' => 'drawer_space_update:1', 'action_label' => '更新' }), 'update not attention')
check.call(!ov.send(:drawer_row_attention?, { 'action' => 'drawer_space_edit:1', 'action_label' => '修改' }), 'edit should be hover-only')
check.call(!ov.send(:drawer_row_attention?, { 'action' => 'drawer_space_disabled:1', 'action_label' => '联动' }), 'disabled linked should not show')
check.call(ov.send(:drawer_row_hidden?, { 'loaded' => true, 'visible' => false }), 'hidden card not detected')
check.call(!ov.send(:drawer_row_hidden?, { 'loaded' => false, 'visible' => false }), 'unloaded card treated as hidden')

FileUtils.rm_rf(TMP)
if failures.empty?
  puts 'PASS'
else
  puts "FAIL: #{failures.join('; ')}"
  exit 1
end
