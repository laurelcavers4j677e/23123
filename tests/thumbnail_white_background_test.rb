# Extract the two methods and run them on synthetic images without SketchUp.
# 用法：ruby tests/thumbnail_white_background_test.rb <解压后的 su_linkhub/runtime.rb>
# 不需要 SketchUp：用最小 ImageRep 替身，在合成图上验证白底校正不会抹掉浅色主体。
src = File.read(ARGV[0] || 'su_linkhub/runtime.rb', encoding: 'utf-8')
def grab(src, name)
  i = src.index("    def #{name}") or raise name
  j = src.index("\n    end\n", i)
  src[i..j + 8]
end
fill = src.include?('def soft_thumbnail_fill_erased_subject?') ? grab(src, 'soft_thumbnail_fill_erased_subject?') : ''
norm = grab(src, 'normalize_soft_thumbnail_white_background!')
module Sketchup
  def self.platform; :platform_win; end
  class ImageRep
    attr_accessor :width, :height, :bits_per_pixel, :row_padding, :data
    @@store = {}
    def self.store; @@store; end
    def load_file(p); @width, @height, @bits_per_pixel, @row_padding, @data = @@store.fetch(p); end
    def set_data(w, h, b, pad, d); @width, @height, @bits_per_pixel, @row_padding, @data = w, h, b, pad, d; end
    def save_file(p); @@store[p] = [@width, @height, @bits_per_pixel, @row_padding, @data]; File.write(p, 'x'); end
  end
end
require 'securerandom'
class T
  def log(m); puts "  log: #{m}"; end
  def log_exception(m, e); puts "  EXC #{m} #{e.message}"; end
  def soft_thumbnail_binary_format(_p); :png; end
  def linkhub_mv(a, b); Sketchup::ImageRep.store[b] = Sketchup::ImageRep.store.delete(a); File.rename(a, b); end
end
T.class_eval(fill); T.class_eval(norm)
def img(body_rgb, edge: nil, bg: [255,255,255], w: 128, h: 128)
  d = ''.b
  h.times { |y| w.times { |x|
    inside = x.between?(30, 97) && y.between?(40, 87)
    border = edge && inside && (x == 30 || x == 97 || y == 40 || y == 87)
    c = border ? edge : (inside ? body_rgb : bg)
    d << [c[2], c[1], c[0]].pack('C*') } }
  [w, h, 24, 0, d]
end
# 只统计家具区域（x 30..97, y 40..87）里“不是纯白”的像素，背景变化不计入。
def subject(d, w = 128)
  d.bytes.each_slice(3).each_with_index.count do |px, i|
    x = i % w; y = i / w
    x.between?(30, 97) && y.between?(40, 87) && px.min < 245
  end
end
t = T.new
failures = []
{ 'lining 244,240,234 no outline' => img([244,240,234]),
  'fabric 199,191,178 no outline' => img([199,191,178]),
  'lining with outline' => img([244,240,234], edge: [60,60,60]),
  'dark grey bg + dark body' => img([60,58,55], bg: [120,120,120]) }.each do |name, im|
  path = "/tmp/linkhub_thumb_test_#{name.tr(' ,', '__')}.png"; File.write(path, 'x'); Sketchup::ImageRep.store[path] = im
  before = subject(im[4]); t.normalize_soft_thumbnail_white_background!(path)
  after = subject(Sketchup::ImageRep.store[path][4])
  puts "#{name}: subject px before=#{before} after=#{after}"
  failures << name if after < before * 0.5
end
abort("FAIL: subject erased in #{failures.join(', ')}") unless failures.empty?
puts 'PASS'

