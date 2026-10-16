# 模拟 SketchUp：检查软装模型库“请先点击修改”报错按原因给出具体提示。
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'securerandom'; require 'tmpdir'; require 'sketchup'
SRC = ARGV[0] or abort('usage: ruby tests/sim/editing_space_message_sim.rb <su_linkhub dir>')
TMP = Dir.mktmpdir('lhsim'); ENV['TEMP'] = File.join(TMP, 'temp'); FileUtils.mkdir_p ENV['TEMP']
model = Sketchup::Model.new; Sketchup.active_model = model
Kernel.load(File.join(SRC, 'main.rb'))
RT = GavinTools::SULinkHubMultiSpace::Runtime
LOGS = []; RT.define_singleton_method(:log) { |m, *_| LOGS << m.to_s }
item = { 'id' => 'S4', 'number' => '4', 'name' => '顶层公区', 'collection_key' => 'soft' }
state = { 'space_models' => [item], 'space_editing_id' => 'S4' }
cases = {
  'no_edit' => [{ 'space_models' => [item], 'space_editing_id' => '' }, nil, {}],
  'root_missing' => [state, nil, { 'exists' => true, 'stale' => false, 'owned' => true }],
  'lock_missing' => [state, :ent, { 'exists' => false }],
  'lock_stale' => [state, :ent, { 'exists' => true, 'stale' => true, 'owned' => true }],
  'other' => [state, :ent, { 'exists' => true, 'stale' => false, 'owned' => false, 'owner' => '王工' }],
  'ok' => [state, :ent, { 'exists' => true, 'stale' => false, 'owned' => true }]
}
d = model.definitions.add('space'); ent = model.entities.add_instance(d, Geom::Transformation.new)
cases.each do |k, (st, e, lock)|
  RT.define_singleton_method(:space_model_entity) { |*_| e == :ent ? ent : nil }
  RT.define_singleton_method(:space_lock_info) { |*_a, **_k| lock }
  RT.define_singleton_method(:find_nested_managed_entities) { |*_a, **_k| [] }
  begin
    r = RT.current_local_editing_space(st, model, required: true)
    puts "#{k}: OK #{r[1] && r[1]['name']}"
  rescue => ex
    puts "#{k}: #{ex.message}"
  end
end
puts LOGS.grep(/不可用/).first
FileUtils.rm_rf(TMP)
