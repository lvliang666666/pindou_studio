/// 拼豆色卡：多品牌支持。
///
/// 内置 7 套色卡（通用卡 + 6 个品牌卡），见 palette_data.dart。
/// [BeadPalette] 保留静态 API（colors/nearest/byCode/groups），
/// 委托到"当前色卡"——现有调用方（转换引擎、UI、测试）无需改动；
/// 切换色卡用 [BeadPalette.setActive]。
library;

import 'dart:math' as math;

import 'palette_data.dart';

/// 单个拼豆颜色。
class BeadColor {
  const BeadColor({
    required this.code,
    required this.name,
    required this.red,
    required this.green,
    required this.blue,
  });

  /// 色号，如 "A1"（品牌内唯一）。
  final String code;

  /// 颜色名称（中文或色号本身）。
  final String name;

  final int red;
  final int green;
  final int blue;

  /// 0xAARRGGBB 形式的整数值。
  int get argb => 0xFF000000 | (red << 16) | (green << 8) | blue;

  /// 0xRRGGBB 形式的整数值。
  int get rgb => (red << 16) | (green << 8) | blue;

  /// 色系分组名。
  String get group => BeadPalette.groupOf(this);

  @override
  String toString() => '$code $name';

  /// 按色号判等：色卡中每个编号唯一，编号相同即同一颜色。
  /// 统计用 `Map<BeadColor, int>` 聚合，按 code 判等可保证
  /// 任何路径产生的同色对象都合并到一行，绝不出现重复行。
  @override
  bool operator ==(Object other) => other is BeadColor && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

/// 一套色卡：品牌名 + 颜色列表 + 派生索引。
class BeadPaletteSet {
  BeadPaletteSet._(this.id, this.displayName, List<BeadColor> colors)
      : colors = List.unmodifiable(colors),
        byCode = {for (final c in colors) c.code: c},
        groups = _buildGroups(colors),
        _sorted = _buildSorted(colors);

  /// 稳定标识（持久化用）：'default'/'mard'/'coco'/'artkal'/
  /// 'artkal-mini'/'hama'/'perler'。
  final String id;

  /// 显示名。
  final String displayName;

  /// 全部颜色（不可变）。
  final List<BeadColor> colors;

  /// 编号 -> 颜色 的快速索引。
  final Map<String, BeadColor> byCode;

  /// 按色系分组的颜色。
  final Map<String, List<BeadColor>> groups;

  /// 按亮度排序的副本（最近色查找用，懒构建已在此完成）。
  final List<BeadColor> _sorted;

  /// 找到与给定 RGB 最接近的拼豆颜色（加权欧氏距离 + 亮度二分）。
  BeadColor nearest(int r, int g, int b) {
    final list = _sorted;
    final targetL = _luma(r, g, b);
    int lo = 0, hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_lumaOf(list[mid]) < targetL) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    var best = list[0];
    var bestD = _distance(best, r, g, b);
    for (int i = lo; i < list.length; i++) {
      final dl = _lumaOf(list[i]) - targetL;
      if (dl * dl > bestD) break;
      final d = _distance(list[i], r, g, b);
      if (d < bestD) {
        bestD = d;
        best = list[i];
      }
    }
    for (int i = lo - 1; i >= 0; i--) {
      final dl = targetL - _lumaOf(list[i]);
      if (dl * dl > bestD) break;
      final d = _distance(list[i], r, g, b);
      if (d < bestD) {
        bestD = d;
        best = list[i];
      }
    }
    return best;
  }

  static double _lumaOf(BeadColor c) => _luma(c.red, c.green, c.blue);

  static double _luma(int r, int g, int b) => 0.299 * r + 0.587 * g + 0.114 * b;

  static double _distance(BeadColor c, int r, int g, int b) {
    final dr = c.red - r, dg = c.green - g, db = c.blue - b;
    // 加权欧氏距离：人眼对绿色最敏感，红色次之，蓝色最弱。
    return 2.0 * dr * dr + 4.0 * dg * dg + 3.0 * db * db;
  }

  static List<BeadColor> _buildSorted(List<BeadColor> colors) {
    final list = List<BeadColor>.of(colors);
    list.sort((a, b) => _lumaOf(a).compareTo(_lumaOf(b)));
    return list;
  }

  static Map<String, List<BeadColor>> _buildGroups(List<BeadColor> colors) {
    final map = <String, List<BeadColor>>{};
    for (final c in colors) {
      map.putIfAbsent(BeadPalette.groupOf(c), () => []).add(c);
    }
    return map;
  }
}

/// 色卡注册表与"当前色卡"静态门面。
class BeadPalette {
  BeadPalette._();

  /// 全部内置色卡（id -> 实例）。
  static final Map<String, BeadPaletteSet> all = {
    for (final def in _defs) def.id: def,
  };

  /// 色卡定义顺序（设置页展示顺序）。
  static final List<BeadPaletteSet> ordered = List.unmodifiable(_defs);

  static final List<BeadPaletteSet> _defs = [
    BeadPaletteSet._('default', '通用色卡', _buildDefaultColors()),
    BeadPaletteSet._('mard', 'MARD（291 色）', [for (final r in kMardRows) _parseRow(r)]),
    BeadPaletteSet._('coco', 'COCO（291 色）', [for (final r in kCocoRows) _parseRow(r)]),
    BeadPaletteSet._('artkal', 'Artkal（176 色）', [for (final r in kArtkalRows) _parseRow(r)]),
    BeadPaletteSet._('artkal-mini', 'Artkal Mini（221 色）', [for (final r in kArtkalMiniRows) _parseRow(r)]),
    BeadPaletteSet._('hama', 'Hama（89 色）', [for (final r in kHamaRows) _parseRow(r)]),
    BeadPaletteSet._('perler', 'Perler（117 色）', [for (final r in kPerlerRows) _parseRow(r)]),
  ];

  /// 当前色卡（默认通用卡）。
  static BeadPaletteSet _active = all['default']!;

  /// 当前生效的色卡。
  static BeadPaletteSet get active => _active;

  /// 切换当前色卡；未知 id 返回 false 且不改动。
  static bool setActive(String id) {
    final set = all[id];
    if (set == null || identical(set, _active)) return false;
    _active = set;
    return true;
  }

  /// 按 id 取色卡；未知 id 回退通用卡。
  static BeadPaletteSet byId(String id) => all[id] ?? all['default']!;

  // ---------- 静态门面（委托到当前色卡，兼容既有调用方） ----------

  /// 当前色卡的全部颜色。
  static List<BeadColor> get colors => _active.colors;

  /// 当前色卡的 编号 -> 颜色 索引。
  static Map<String, BeadColor> get byCode => _active.byCode;

  /// 当前色卡的色系分组。
  static Map<String, List<BeadColor>> get groups => _active.groups;

  /// 当前色卡的最近色查找。
  static BeadColor nearest(int r, int g, int b) => _active.nearest(r, g, b);

  /// 色系判定：按 HSL 色相与明度归类（所有色卡共用）。
  static String groupOf(BeadColor c) {
    final hsl = _rgbToHsl(c.red, c.green, c.blue);
    final h = hsl[0], s = hsl[1], l = hsl[2];
    if (s <= 0.10) {
      if (l >= 0.75) return '白色';
      if (l >= 0.40) return '灰色';
      return '黑色';
    }
    final deg = h * 360;
    if (deg < 15 || deg >= 345) return '红色';
    if (deg < 45) return '橙色';
    if (deg < 70) return '黄色';
    if (deg < 100) return '黄绿色';
    if (deg < 160) return '绿色';
    if (deg < 200) return '青色';
    if (deg < 260) return '蓝色';
    if (deg < 300) return '紫色';
    if (deg < 345) return '粉色';
    return '其他';
  }

  static BeadColor _parseRow(String row) {
    final parts = row.split(',');
    return BeadColor(
      code: parts[0],
      name: parts[1],
      red: int.parse(parts[2]),
      green: int.parse(parts[3]),
      blue: int.parse(parts[4]),
    );
  }

  static List<double> _rgbToHsl(int r, int g, int b) {
    final rf = r / 255, gf = g / 255, bf = b / 255;
    final max = math.max(rf, math.max(gf, bf));
    final min = math.min(rf, math.min(gf, bf));
    final l = (max + min) / 2;
    if (max == min) return [0, 0, l];
    final d = max - min;
    final s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    double h;
    if (max == rf) {
      h = (gf - bf) / d + (gf < bf ? 6 : 0);
    } else if (max == gf) {
      h = (bf - rf) / d + 2;
    } else {
      h = (rf - gf) / d + 4;
    }
    return [h / 6, s, l];
  }

  /// 通用色卡（历史内置 83 色，带中文名）。
  static List<BeadColor> _buildDefaultColors() {
    const rows = <String>[
      // code,name,r,g,b
      // —— 白色系
      'A1,白色,255,255,255',
      'A2,奶白,248,244,231',
      'A3,米白,240,230,210',
      'A4,珍珠白,235,235,240',
      // —— 黑色系
      'B1,黑色,20,20,20',
      'B2,炭黑,45,45,48',
      'B3,深黑灰,70,70,74',
      // —— 灰色系
      'C1,浅灰,210,210,212',
      'C2,银灰,185,185,190',
      'C3,中灰,150,150,155',
      'C4,深灰,105,105,110',
      'C5,蓝灰,120,130,145',
      'C6,暖灰,175,168,158',
      // —— 红色系
      'D1,正红,220,30,40',
      'D2,深红,160,20,30',
      'D3,酒红,120,20,40',
      'D4,砖红,180,70,55',
      'D5,绯红,235,70,70',
      'D6,暗红,100,25,25',
      'D7,玫红,215,30,90',
      // —— 橙色系
      'E1,橙色,245,130,30',
      'E2,深橙,225,95,20',
      'E3,橘色,250,160,60',
      'E4,杏橙,245,180,120',
      'E5,柿橙,235,110,60',
      'E6,棕橙,200,120,60',
      // —— 黄色系
      'F1,柠檬黄,250,230,60',
      'F2,明黄,248,205,50',
      'F3,深黄,235,175,35',
      'F4,奶黄,250,225,160',
      'F5,土黄,215,160,70',
      'F6,金黄,230,190,90',
      'F7,芥末黄,200,170,60',
      // —— 绿色系
      'G1,草绿,110,180,70',
      'G2,深绿,40,110,50',
      'G3,翠绿,60,160,80',
      'G4,浅绿,170,215,130',
      'G5,抹茶绿,150,180,110',
      'G6,橄榄绿,110,120,50',
      'G7,墨绿,25,70,45',
      'G8,荧光绿,140,220,60',
      'G9,豆绿,190,210,160',
      // —— 青色系
      'H1,青色,40,180,170',
      'H2,湖蓝,60,150,190',
      'H3,薄荷绿,140,220,200',
      'H4,孔雀青,20,120,130',
      'H5,浅青,170,220,225',
      'H6,深青,15,90,100',
      // —— 蓝色系
      'I1,宝蓝,30,70,180',
      'I2,深蓝,25,40,110',
      'I3,天蓝,90,160,230',
      'I4,浅蓝,170,205,240',
      'I5,藏青,30,45,80',
      'I6,钴蓝,50,90,200',
      'I7,靛蓝,60,60,140',
      'I8,婴儿蓝,190,215,245',
      // —— 紫色系
      'J1,紫色,130,60,180',
      'J2,深紫,85,35,130',
      'J3,浅紫,195,160,225',
      'J4,薰衣草,180,170,220',
      'J5,葡萄紫,105,45,105',
      'J6,蓝紫,100,80,200',
      // —— 粉色系
      'K1,粉色,245,160,180',
      'K2,桃粉,245,130,150',
      'K3,浅粉,250,205,215',
      'K4,玫粉,230,90,140',
      'K5,肤色,245,200,175',
      'K6,深肤色,225,170,140',
      'K7,珊瑚粉,240,140,120',
      'K8,梅粉,200,80,120',
      // —— 棕色系
      'L1,棕色,140,95,60',
      'L2,深棕,95,60,35',
      'L3,浅棕,190,150,110',
      'L4,咖啡棕,110,75,50',
      'L5,驼色,200,170,130',
      'L6,栗棕,75,45,30',
      'L7,卡其,175,155,110',
      // —— 荧光/特殊
      'M1,荧光粉,255,105,180',
      'M2,荧光黄,255,255,102',
      'M3,荧光橙,255,150,60',
      'M4,荧光青,80,255,220',
      'M5,夜光绿,190,240,170',
      'M6,透明白,250,250,245',
    ];
    return [for (final row in rows) _parseRow(row)];
  }
}
