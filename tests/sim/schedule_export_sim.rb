# frozen_string_literal: true
# 模拟 SketchUp 运行插件真实代码：清单草稿（未提交的分类资料）应用到导出行，生成真实 xlsx，
# 检查总表、家具表、按款汇总都包含“色号/色系”和“品牌/供应商”等清单里填写的内容。
# 用法：ruby tests/sim/schedule_export_sim.rb <su_linkhub 目录>
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'securerandom'
require 'tmpdir'
require 'sketchup'
SRC = ARGV[0] or abort('usage: ruby tests/sim/schedule_export_sim.rb <su_linkhub dir>')
TMP = Dir.mktmpdir('lhxlsx')
ENV['TEMP'] = File.join(TMP, 'temp'); FileUtils.mkdir_p ENV['TEMP']
Sketchup.active_model = Sketchup::Model.new
Kernel.load(File.join(SRC, 'main.rb'))
RT = GavinTools::SULinkHubMultiSpace::Runtime
failures = []

rows = [
  { 'model_id' => 'M1', 'source_path' => '/lib/木箱子.skp', 'name' => '黑色做旧木箱子', 'display_name' => '黑色做旧木箱子',
    'category' => '家具', 'subcategory' => '几类', 'quantity' => 1, 'length_mm' => 900, 'width_mm' => 450, 'height_mm' => 400,
    'space_names' => '顶层公区', 'spaces' => ['4:顶层公区'], 'space_ids' => ['S4'], 'extra_fields' => {}, 'material_description' => '' },
  { 'model_id' => 'M2', 'source_path' => '/lib/圆形茶几.skp', 'name' => '圆形茶几', 'display_name' => '圆形茶几',
    'category' => '家具', 'subcategory' => '几类', 'quantity' => 1, 'length_mm' => 800, 'width_mm' => 800, 'height_mm' => 500,
    'space_names' => '顶层公区', 'spaces' => ['4:顶层公区'], 'space_ids' => ['S4'],
    'extra_fields' => { 'color' => '桌面板：浅木纹', 'brand_supplier' => '定制' }, 'material_description' => '' }
]
drafts = { 'model_drafts' => { 'k1' => { 'model_id' => 'M1', 'source_path' => '/lib/木箱子.skp',
  'values' => { 'name' => '木箱子', 'extra_fields' => { 'color' => '黑色做旧', 'brand_supplier' => '淘老货' } },
  'changed' => { 'name' => true, 'extra_fields' => { 'color' => true, 'brand_supplier' => true } } } }, 'dimension_drafts' => {} }
drafted, count = RT.soft_schedule_apply_export_drafts(rows, JSON.generate(drafts))
failures << "draft count #{count}" unless count == 1
_t, headers, body, = RT.soft_schedule_summary_table(drafted)
row = body.find { |r| r.include?('木箱子') }
mat = row[headers.index('材质描述')].to_s
brand = headers.index('品牌/供应商') ? row[headers.index('品牌/供应商')].to_s : ''
puts "总表 木箱子: 材质描述=#{mat.inspect} 品牌/供应商=#{brand.inspect}"
failures << 'summary missing color' unless mat.include?('色号/色系：黑色做旧')
failures << 'summary missing brand' unless brand == '淘老货'
_t2, h2, b2, = RT.soft_schedule_category_table(drafted, '家具')
r2 = b2.find { |r| r.include?('木箱子') }
failures << 'furniture sheet missing color/brand' unless r2[h2.index('色号/色系')] == '黑色做旧' && r2[h2.index('品牌/供应商')] == '淘老货'

# 写出真实 xlsx，再解压检查共享字符串/单元格里有这些文字
target = File.join(TMP, 'out.xlsx')
sheets = [{ name: '总表', title: '软装总采购清单', headers: headers, rows: body, row_groups: [] },
          { name: '家具', title: '家具清单', headers: h2, rows: b2, row_groups: [] }]
RT.write_soft_schedule_xlsx!(target, sheets)
require 'zlib'
xml = +''
data = File.binread(target)
pos = 0
while (i = data.index("PK\x03\x04".b, pos))
  method = data[i + 8, 2].unpack1('v'); csize = data[i + 18, 4].unpack1('V')
  nlen = data[i + 26, 2].unpack1('v'); elen = data[i + 28, 2].unpack1('v')
  name = data[i + 30, nlen]; start = i + 30 + nlen + elen
  raw = data[start, csize]
  if name.end_with?('.xml')
    xml << (method == 8 ? Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(raw) : raw).force_encoding('UTF-8')
  end
  pos = start + csize
end
%w[色号/色系：黑色做旧 淘老货 品牌/供应商 木箱子].each { |text| failures << "xlsx missing #{text}" unless xml.include?(text) }
puts "xlsx bytes=#{File.size(target)}"
FileUtils.rm_rf(TMP)
if failures.empty?
  puts 'PASS'
else
  puts "FAIL: #{failures.join('; ')}"
  exit 1
end
