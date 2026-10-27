import 'dart:convert';

import '../core/converter.dart';
import '../core/palette.dart';

/// 已保存的拼豆项目（可持久化的图纸工程）。
///
/// 存储设计：
/// - 图纸格子用「色号 + 行程长度（RLE）」编码，90 色色号都很短，
///   87x87 图纸 JSON 通常只有几 KB。
/// - 手动编辑单独存（坐标 -> 色号），加载后可继续编辑/撤销语义一致。
/// - 原图字节不进 JSON（体积大），由仓库层存到 `sources/<id>.<ext>`，
///   本模型只记录扩展名（sourceExt）与尺寸；无原图的旧项目照常打开。
class SavedProject {
  SavedProject({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.width,
    required this.height,
    required this.cellCodes,
    this.manualEdits = const {},
    this.sourceFileName,
    this.sourceWidth,
    this.sourceHeight,
    this.sourceExt,
    this.dither = true,
    this.brightness = 0,
    this.contrast = 0,
    this.colorLimit = 0,
    this.removeBackground = false,
    this.bgTolerance = 32,
    this.paletteId = 'default',
  });

  /// 唯一 id（同时是存储文件名，不含扩展名）。
  final String id;

  /// 项目显示名。
  String name;

  final DateTime createdAt;
  DateTime updatedAt;

  /// 图纸尺寸（豆数）。
  final int width;
  final int height;

  /// 每格色号，行优先，长度 = width * height。
  final List<String> cellCodes;

  /// 手动编辑：坐标 "x,y" -> 色号。
  final Map<String, String> manualEdits;

  /// 来源图片信息（仅展示用）。
  final String? sourceFileName;
  final int? sourceWidth;
  final int? sourceHeight;

  /// 原图扩展名（不含点，如 'png'/'jpg'）；null = 未留存原图。
  /// 原图字节由 ProjectRepository 存取（`sources/<id>.<ext>`），不进 JSON。
  final String? sourceExt;

  /// 转换参数快照（重新转换时可用）。
  final bool dither;
  final int brightness;
  final int contrast;
  final int colorLimit;

  /// 自动抠背景开关（旧项目无此字段时回退 false）。
  final bool removeBackground;

  /// 抠背景容差（旧项目无此字段时回退 32）。
  final int bgTolerance;

  /// 所用色卡 id（旧项目无此字段时回退 'default'）。
  final String paletteId;

  /// 从图纸构建项目。空格（null 格）编码为空字符串色号。
  factory SavedProject.fromPattern({
    required String id,
    required String name,
    required BeadPattern pattern,
    Map<String, String> manualEdits = const {},
    String? sourceFileName,
    int? sourceWidth,
    int? sourceHeight,
    String? sourceExt,
    bool dither = true,
    int brightness = 0,
    int contrast = 0,
    int colorLimit = 0,
    bool removeBackground = false,
    int bgTolerance = 32,
    String paletteId = 'default',
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    final now = DateTime.now();
    return SavedProject(
      id: id,
      name: name,
      createdAt: createdAt ?? now,
      updatedAt: updatedAt ?? now,
      width: pattern.width,
      height: pattern.height,
      cellCodes: [for (final c in pattern.cells) c?.code ?? ''],
      manualEdits: Map.of(manualEdits),
      sourceFileName: sourceFileName,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      sourceExt: sourceExt,
      dither: dither,
      brightness: brightness,
      contrast: contrast,
      colorLimit: colorLimit,
      removeBackground: removeBackground,
      bgTolerance: bgTolerance,
      paletteId: paletteId,
    );
  }

  /// 还原为图纸（色号无效的格子跳过，返回 null 表示数据损坏）。
  /// 空字符串色号 = 空格（不放豆）。
  BeadPattern? toPattern() {
    if (cellCodes.length != width * height) return null;
    final cells = <BeadColor?>[];
    for (final code in cellCodes) {
      if (code.isEmpty) {
        cells.add(null);
        continue;
      }
      final bead = BeadPalette.byCode[code];
      if (bead == null) return null;
      cells.add(bead);
    }
    final counts = <BeadColor, int>{};
    for (final c in cells) {
      if (c == null) continue;
      counts[c] = (counts[c] ?? 0) + 1;
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return a.key.code.compareTo(b.key.code);
      });
    return BeadPattern(
      width: width,
      height: height,
      cells: List.unmodifiable(cells),
      counts: List.unmodifiable([
        for (final e in sorted) BeadCount(color: e.key, count: e.value),
      ]),
    );
  }

  // ---------- JSON ----------

  Map<String, dynamic> toJson() => {
        'version': 1,
        'id': id,
        'name': name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'width': width,
        'height': height,
        // RLE：[色号, 连续数量, 色号, 连续数量, ...]
        'cells': _encodeRle(cellCodes),
        'manualEdits': manualEdits,
        if (sourceFileName != null) 'sourceFileName': sourceFileName,
        if (sourceWidth != null) 'sourceWidth': sourceWidth,
        if (sourceHeight != null) 'sourceHeight': sourceHeight,
        if (sourceExt != null) 'sourceExt': sourceExt,
        'dither': dither,
        'brightness': brightness,
        'contrast': contrast,
        'colorLimit': colorLimit,
        if (removeBackground) 'removeBackground': removeBackground,
        if (removeBackground) 'bgTolerance': bgTolerance,
        'paletteId': paletteId,
      };

  String toJsonString() => jsonEncode(toJson());

  factory SavedProject.fromJson(Map<String, dynamic> json) {
    final width = json['width'] as int;
    final height = json['height'] as int;
    return SavedProject(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? '未命名',
      createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(json['updatedAt'] as int),
      width: width,
      height: height,
      cellCodes: _decodeRle(
        (json['cells'] as List).cast<dynamic>(),
        width * height,
      ),
      manualEdits: (json['manualEdits'] as Map<String, dynamic>? ?? {})
          .map((k, v) => MapEntry(k, v as String)),
      sourceFileName: json['sourceFileName'] as String?,
      sourceWidth: json['sourceWidth'] as int?,
      sourceHeight: json['sourceHeight'] as int?,
      sourceExt: json['sourceExt'] as String?,
      dither: json['dither'] as bool? ?? true,
      brightness: json['brightness'] as int? ?? 0,
      contrast: json['contrast'] as int? ?? 0,
      colorLimit: json['colorLimit'] as int? ?? 0,
      removeBackground: json['removeBackground'] as bool? ?? false,
      bgTolerance: json['bgTolerance'] as int? ?? 32,
      paletteId: json['paletteId'] as String? ?? 'default',
    );
  }

  /// 从 JSON 文本解析；格式错误返回 null。
  static SavedProject? tryParseJson(String text) {
    try {
      return SavedProject.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// 生成新项目 id（时间戳 + 随机后缀，同时用作存储文件名）。
  static String newId() {
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final rand = (DateTime.now().microsecondsSinceEpoch % 46656)
        .toRadixString(36)
        .padLeft(3, '0');
    return 'p_${ts}_$rand';
  }

  /// RLE 编码：["A1", 12, "B3", 5, ...]。
  static List<dynamic> _encodeRle(List<String> codes) {
    final out = <dynamic>[];
    var i = 0;
    while (i < codes.length) {
      final code = codes[i];
      var run = 1;
      while (i + run < codes.length && codes[i + run] == code) {
        run++;
      }
      out..add(code)..add(run);
      i += run;
    }
    return out;
  }

  /// RLE 解码；总长不符时抛 FormatException。
  /// pairs 为混合类型 [色号(String), 数量(int), ...]（JSON 解码产物）。
  static List<String> _decodeRle(List<dynamic> pairs, int total) {
    final out = <String>[];
    if (pairs.length.isOdd) throw const FormatException('RLE 长度为奇数');
    for (var i = 0; i < pairs.length; i += 2) {
      final code = pairs[i];
      if (code is! String) throw const FormatException('RLE 色号非字符串');
      final runRaw = pairs[i + 1];
      final run = runRaw is int ? runRaw : int.tryParse('$runRaw');
      if (run == null || run < 1) throw const FormatException('RLE 长度无效');
      out.addAll(List.filled(run, code));
    }
    if (out.length != total) throw const FormatException('RLE 总长不符');
    return out;
  }
}
