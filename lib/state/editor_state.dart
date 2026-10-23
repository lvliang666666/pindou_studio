import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../core/converter.dart';
import '../core/palette.dart';
import '../data/project_model.dart';
import '../data/project_repository.dart';

export '../core/converter.dart' show BeadPattern, BeadCount, ConvertOptions;
export '../core/palette.dart' show BeadColor, BeadPalette;

/// 编辑器状态：图片加载、参数、转换、结果、手动编辑与项目保存/加载。
///
/// 由原 AppState 演化而来，新增：
/// - [projectId]/[projectName]：当前绑定的已保存项目（null = 未保存的新项目）
/// - [hasUnsavedChanges]：脏标记，编辑/重转后置位，保存后清除
/// - [save]/[loadProject]：项目持久化
class EditorState extends ChangeNotifier {
  EditorState({ProjectRepository? repository})
      : repository = repository ?? ProjectRepository() {
    // 默认参数：29x29 标准底板。
    gridWidthCtrl.text = '29';
    gridHeightCtrl.text = '29';
  }

  /// 项目仓库。
  final ProjectRepository repository;

  /// 当前项目 id（null = 尚未保存过的新项目）。
  String? projectId;

  /// 当前项目名。
  String projectName = '';

  /// 是否有未保存的修改。
  bool hasUnsavedChanges = false;

  /// 项目创建时间（保存时固化）。
  DateTime? createdAt;

  /// 原始解码图像（RGBA 像素）。
  Uint8List? _pixels;
  int _srcWidth = 0;
  int _srcHeight = 0;
  String? _fileName;

  /// 转换结果。
  BeadPattern? pattern;

  /// 原图预览（用于左侧缩略图）。
  ImageProvider? previewImage;

  /// 参数控件。
  final gridWidthCtrl = TextEditingController();
  final gridHeightCtrl = TextEditingController();
  bool dither = true;
  double brightness = 0;
  double contrast = 0;
  int colorLimit = 0; // 0 = 不限制

  /// 锁定宽高比：修改宽度时按原图比例自动计算高度（反之亦然）。
  bool lockRatio = true;

  /// 当前色卡 id（BeadPalette.active.id 的镜像，供 UI 与项目保存）。
  String paletteId = 'default';

  /// 切换色卡：立即生效并重新转换（原图在时）或仅刷新（已加载项目）。
  void setPalette(String id) {
    if (!BeadPalette.setActive(id)) return;
    paletteId = BeadPalette.active.id;
    // 画笔色号属于旧色卡，切换后失效。
    brushCode = null;
    if (_pixels != null) {
      scheduleReconvert();
    } else {
      // 已加载项目（无原图）：色号可能在新色卡中不存在，
      // 重建 pattern（无效色号格子置为色卡首色）。
      _remapPatternToActivePalette();
      notifyListeners();
    }
    hasUnsavedChanges = true;
  }

  /// 把当前 pattern 的色号重映射到当前色卡（项目加载/色卡切换用）。
  void _remapPatternToActivePalette() {
    final p = pattern;
    if (p == null) return;
    final byCode = BeadPalette.byCode;
    final cells = [
      for (final c in p.cells) byCode[c.code] ?? byCode.values.first,
    ];
    pattern = _rebuildCounts(cells, p.width, p.height);
  }

  /// 手动编辑记录：坐标 -> 颜色编号。重新转换时保留同坐标的编辑。
  final Map<String, String> manualEdits = {};

  /// 被编辑格子的自动转换色（用于"涂回原色即清除编辑"与右键擦除）。
  final Map<String, String> _autoCodes = {};

  /// 撤销/重做栈（每项为一笔笔画）。
  final List<_Stroke> _undoStack = [];
  final List<_Stroke> _redoStack = [];
  _Stroke? _currentStroke;

  /// 是否可撤销/重做。
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// 画笔色号（null = 未启用画笔，点击格子弹选色框）。
  String? brushCode;

  bool _converting = false;
  bool get converting => _converting;

  String? get fileName => _fileName;
  int get srcWidth => _srcWidth;
  int get srcHeight => _srcHeight;

  /// 防抖定时器：参数变化后自动重新转换。
  Timer? _debounce;

  /// 标记脏状态并通知。
  void _markDirtyAndNotify() {
    hasUnsavedChanges = true;
    notifyListeners();
  }

  /// 加载图片文件字节。
  Future<void> loadImage(Uint8List bytes, String fileName) async {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('无法解码图片文件');
    }
    // 统一转为 RGBA（4 字节/像素）。JPEG 解码输出 3 通道、GIF 输出 1 通道调色板索引，
    // 直接 toUint8List() 会导致转换引擎按 4 字节步进访问越界。
    _pixels = Uint8List.fromList(
        decoded.getBytes(order: img.ChannelOrder.rgba, alpha: 255));
    _srcWidth = decoded.width;
    _srcHeight = decoded.height;
    _fileName = fileName;
    previewImage = MemoryImage(bytes);
    await reconvert();
  }

  /// 参数变化时调用（自动防抖重转）。
  void scheduleReconvert() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      reconvert();
    });
  }

  void setDither(bool v) {
    dither = v;
    scheduleReconvert();
  }

  void setBrightness(double v) {
    brightness = v;
    scheduleReconvert();
  }

  void setContrast(double v) {
    contrast = v;
    scheduleReconvert();
  }

  void setColorLimit(int v) {
    colorLimit = v;
    scheduleReconvert();
  }

  void setLockRatio(bool v) {
    lockRatio = v;
    notifyListeners();
  }

  /// 设置/清除画笔颜色。
  void setBrush(String? code) {
    brushCode = code;
    notifyListeners();
  }

  /// 输入宽度：只更新文本，不联动、不渲染。
  /// 渲染时机完全由"确认"按钮/回车/失焦触发（confirmGridSize）。
  void setGridWidth(String text) {}

  /// 输入高度：只更新文本，不联动、不渲染。
  void setGridHeight(String text) {}

  /// 确认图纸尺寸：按锁定比例联动校验后触发重新转换。
  /// 回车/失焦/预设/确认按钮都会走到这里。
  /// [fromField] 指明用户最后编辑的是哪个框：联动以它为准
  /// （'w' = 以宽算高，'h' = 以高算宽，null = 默认以宽为准）。
  void confirmGridSize({String? fromField}) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      var gw = int.tryParse(gridWidthCtrl.text) ?? 0;
      var gh = int.tryParse(gridHeightCtrl.text) ?? 0;
      // 锁定比例时以最后编辑的框为准联动另一个框。
      if (lockRatio && _srcWidth > 0) {
        if (fromField == 'h' && gh >= 1) {
          gw = (gh * _srcWidth / _srcHeight).round().clamp(1, 500);
          if (gridWidthCtrl.text != '$gw') gridWidthCtrl.text = '$gw';
        } else if (gw >= 1) {
          gh = (gw * _srcHeight / _srcWidth).round().clamp(1, 500);
          if (gridHeightCtrl.text != '$gh') gridHeightCtrl.text = '$gh';
        }
      }
      if (gw < 1 || gh < 1) return; // 无效输入不渲染
      await reconvert();
    });
  }

  /// 手动替换某格颜色（按色号），并更新统计。单独一步，可撤销。
  /// 返回实际应用的颜色；格子无变化时返回 null。
  BeadColor? editCell(int x, int y, BeadColor color) => paintCell(x, y, color);

  /// 画笔涂色：笔画内（beginStroke/endStroke 之间）连续涂色合并为一步撤销。
  /// 返回实际应用的颜色；格子无变化时返回 null。
  BeadColor? paintCell(int x, int y, BeadColor color) {
    return _applyCellEdit(x, y, color.code);
  }

  /// 擦除：恢复该格为自动转换色。返回恢复后的颜色；无编辑记录时返回 null。
  BeadColor? eraseCell(int x, int y) {
    final auto = _autoCodes['$x,$y'];
    if (auto == null) return null;
    return _applyCellEdit(x, y, auto);
  }

  /// 应用单格编辑，返回实际写入的颜色；无变化时返回 null。
  BeadColor? _applyCellEdit(int x, int y, String code) {
    final p = pattern;
    if (p == null) return null;
    final bead = BeadPalette.byCode[code];
    if (bead == null) return null;
    if (x < 0 || x >= p.width || y < 0 || y >= p.height) return null;
    final idx = y * p.width + x;
    // "当前值"判断：笔画中用可变副本（pattern.cells 是笔画开始时的
    // 旧内容——同一笔画内"涂走再涂回/擦回原色"时，旧列表恰好等于
    // 目标色，用它判断会把真实编辑误判为无变化而跳过）。
    final current = _currentStroke != null ? _mutableCells![idx] : p.cells[idx];
    if (current.code == code) return null;

    final key = '$x,$y';
    final oldCode = current.code;
    // 首次编辑该格时记录其自动转换色。
    if (!manualEdits.containsKey(key) && !_autoCodes.containsKey(key)) {
      _autoCodes[key] = oldCode;
    }
    if (_autoCodes[key] == code) {
      manualEdits.remove(key); // 涂回自动色 = 无编辑
    } else {
      manualEdits[key] = code;
    }

    final stroke = _currentStroke;
    if (stroke != null) {
      // ===== 笔画中：快速路径 =====
      // 直接改可变 cells + 增量更新计数，不拷贝列表、不全量重统计。
      // pattern 对象保持同一实例（画布不触发重新光栅化）。
      stroke.dirty = true;
      // 旧色取可变副本中的当前值（同一笔画内重复涂同一格时，
      // pattern.cells 仍是笔画开始时的旧内容，用它减计数会算错）。
      final prevBead = _mutableCells![idx];
      _mutableCells![idx] = bead;
      _bumpCount(prevBead, -1);
      _bumpCount(bead, 1);
      // 同一笔画内重复涂同一格：合并为一条记录。
      final i = stroke.edits.indexWhere((e) => e.x == x && e.y == y);
      if (i >= 0) {
        stroke.edits[i] = _CellEdit(x, y, stroke.edits[i].oldCode, code);
      } else {
        stroke.edits.add(_CellEdit(x, y, oldCode, code));
      }
      notifyListeners();
    } else {
      // ===== 单格点击：完整路径（拷贝 + 重统计，可撤销一步） =====
      final newCells = List<BeadColor>.of(p.cells);
      newCells[idx] = bead;
      pattern = _rebuildCounts(newCells, p.width, p.height);
      _pushUndo(_Stroke()..edits.add(_CellEdit(x, y, oldCode, code)));
      _markDirtyAndNotify();
    }
    return bead;
  }

  /// 笔画期间的可变格子列表（与 pattern.cells 同内容）。
  List<BeadColor>? _mutableCells;

  /// 笔画期间的可变计数表（颜色 -> 数量）。
  Map<BeadColor, int>? _mutableCounts;

  /// 增量更新颜色计数（笔画期间避免全量重统计）。
  void _bumpCount(BeadColor color, int delta) {
    final counts = _mutableCounts;
    if (counts == null) return;
    final newCount = (counts[color] ?? 0) + delta;
    if (newCount <= 0) {
      counts.remove(color);
    } else {
      counts[color] = newCount;
    }
  }

  void _pushUndo(_Stroke stroke) {
    _undoStack.add(stroke);
    _redoStack.clear();
    if (_undoStack.length > 200) _undoStack.removeAt(0);
  }

  /// 开始一笔笔画。
  void beginStroke() {
    _currentStroke = _Stroke();
    final p = pattern;
    if (p != null) {
      // cells/counts 均不可变（List.unmodifiable），复制可变副本供笔画快速写入。
      _mutableCells = List<BeadColor>.of(p.cells);
      // 按 code 累加（BeadColor 已按 code 判等）：万一历史数据里
      // 同色出现多条，这里合并数量而不是覆盖，避免丢数量。
      _mutableCounts = <BeadColor, int>{};
      for (final bc in p.counts) {
        _mutableCounts![bc.color] = (_mutableCounts![bc.color] ?? 0) + bc.count;
      }
    }
  }

  /// 结束当前笔画；有实际改动时入撤销栈并重建 pattern（触发画布重光栅化）。
  void endStroke() {
    final stroke = _currentStroke;
    _currentStroke = null;
    final mutable = _mutableCells;
    _mutableCells = null;
    if (stroke != null && stroke.edits.isNotEmpty) {
      final p = pattern;
      if (p != null && mutable != null && _mutableCounts != null) {
        // 笔画结束：用最终 cells 与增量计数重建不可变 pattern。
        pattern = _rebuildFromCounts(
            mutable, p.width, p.height, _mutableCounts!);
      }
      _mutableCounts = null;
      _pushUndo(stroke);
      _markDirtyAndNotify();
    } else {
      _mutableCounts = null;
    }
  }

  /// 用增量维护的计数表重建 pattern（按数量降序）。
  static BeadPattern _rebuildFromCounts(
    List<BeadColor> cells,
    int width,
    int height,
    Map<BeadColor, int> counts,
  ) {
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

  /// 撤销上一步（一笔笔画）。
  void undo() {
    if (_undoStack.isEmpty) return;
    final stroke = _undoStack.removeLast();
    _applyStroke(stroke, useNewCode: false);
    _redoStack.add(stroke);
    _markDirtyAndNotify();
  }

  /// 重做被撤销的一步。
  void redo() {
    if (_redoStack.isEmpty) return;
    final stroke = _redoStack.removeLast();
    _applyStroke(stroke, useNewCode: true);
    _undoStack.add(stroke);
    _markDirtyAndNotify();
  }

  /// 撤销/重做：把一笔笔画的所有格子批量恢复。
  /// 一次拷贝 cells + 一次重统计（此前逐格拷贝+重统计，大笔画卡顿）。
  void _applyStroke(_Stroke stroke, {required bool useNewCode}) {
    final p = pattern;
    if (p == null) return;
    final cells = List<BeadColor>.of(p.cells);
    var changed = false;
    for (final e in stroke.edits) {
      final code = useNewCode ? e.newCode : e.oldCode;
      final bead = BeadPalette.byCode[code];
      if (bead == null) continue;
      if (e.x < 0 || e.x >= p.width || e.y < 0 || e.y >= p.height) continue;
      final idx = e.y * p.width + e.x;
      if (cells[idx].code == code) continue;
      cells[idx] = bead;
      changed = true;

      final key = '${e.x},${e.y}';
      if (_autoCodes[key] == code) {
        manualEdits.remove(key);
      } else {
        manualEdits[key] = code;
      }
    }
    if (changed) {
      pattern = _rebuildCounts(cells, p.width, p.height);
    }
  }

  /// 清除全部手动编辑并重新转换。
  Future<void> clearManualEdits() async {
    if (manualEdits.isEmpty) return;
    manualEdits.clear();
    await reconvert();
  }

  static BeadPattern _rebuildCounts(
    List<BeadColor> cells,
    int width,
    int height,
  ) {
    final counts = <BeadColor, int>{};
    for (final c in cells) {
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

  /// 执行转换（同步，图片较大时由调用方放在 isolate 中）。
  Future<void> reconvert() async {
    if (_pixels == null) return;
    final gw = int.tryParse(gridWidthCtrl.text) ?? 29;
    final gh = int.tryParse(gridHeightCtrl.text) ?? 29;
    if (gw < 1 || gh < 1) return;
    _converting = true;
    notifyListeners();
    try {
      // 在 isolate 中执行转换，避免大图卡 UI。
      final result = await _convertInIsolate(
        _pixels!, _srcWidth, _srcHeight,
        ConvertOptions(
          gridWidth: gw,
          gridHeight: gh,
          dither: dither,
          brightness: brightness.round(),
          contrast: contrast.round(),
          colorLimit: colorLimit,
        ),
      );
      // 参数变化后基准图已变，撤销/重做历史作废。
      _undoStack.clear();
      _redoStack.clear();
      _currentStroke = null;
      // 重新转换后应用仍有效的手动编辑（坐标在范围内才保留）。
      if (manualEdits.isNotEmpty) {
        final cells = List<BeadColor>.of(result.cells);
        final validEdits = <String, String>{};
        manualEdits.forEach((key, code) {
          final parts = key.split(',');
          final ex = int.parse(parts[0]);
          final ey = int.parse(parts[1]);
          if (ex < result.width && ey < result.height) {
            final bead = BeadPalette.byCode[code];
            if (bead != null) {
              cells[ey * result.width + ex] = bead;
              validEdits[key] = code;
            }
          }
        });
        manualEdits
          ..clear()
          ..addAll(validEdits);
        // 重建自动色表：仅保留仍处于编辑状态的格子。
        _autoCodes
          ..clear()
          ..addAll({
            for (final key in validEdits.keys)
              key: result.cells[
                      int.parse(key.split(',')[1]) * result.width +
                          int.parse(key.split(',')[0])]
                  .code,
          });
        pattern = _rebuildCounts(cells, result.width, result.height);
      } else {
        _autoCodes.clear();
        pattern = result;
      }
      hasUnsavedChanges = true;
    } finally {
      _converting = false;
      // 单次通知：UI 层（editor_page）检测 converting 下降沿，
      // 让画布在遮罩下先完成重绘，遮罩移除帧再更新统计面板。
      notifyListeners();
    }
  }

  static Future<BeadPattern> _convertInIsolate(
    Uint8List pixels,
    int srcW,
    int srcH,
    ConvertOptions options,
  ) async {
    // Flutter 桌面端支持 compute。
    return compute(_convertSync, _ConvertArgs(pixels, srcW, srcH, options));
  }

  static BeadPattern _convertSync(_ConvertArgs args) {
    return BeadConverter.convert(
      pixels: args.pixels,
      srcWidth: args.srcWidth,
      srcHeight: args.srcHeight,
      options: args.options,
    );
  }

  // ---------- 项目保存 / 加载 ----------

  /// 保存当前项目。新项目自动生成 id；[name] 为空时用原文件名或默认名。
  /// 返回项目 id。
  Future<String> save({String? name}) async {
    final p = pattern;
    if (p == null) throw StateError('没有可保存的图纸');
    final id = projectId ?? _newId();
    final now = DateTime.now();
    final project = SavedProject.fromPattern(
      id: id,
      name: name ??
          (projectName.isNotEmpty ? projectName : (_fileName ?? '未命名项目')),
      pattern: p,
      manualEdits: manualEdits,
      sourceFileName: _fileName,
      sourceWidth: _srcWidth > 0 ? _srcWidth : null,
      sourceHeight: _srcHeight > 0 ? _srcHeight : null,
      dither: dither,
      brightness: brightness.round(),
      contrast: contrast.round(),
      colorLimit: colorLimit,
      paletteId: paletteId,
      createdAt: createdAt,
      updatedAt: now,
    );
    final thumb = await ProjectRepository.renderThumbnail(p);
    await repository.saveProject(project, thumbnailPng: thumb);
    projectId = id;
    projectName = project.name;
    createdAt ??= now;
    hasUnsavedChanges = false;
    notifyListeners();
    return id;
  }

  /// 从已保存项目恢复编辑器状态。
  Future<void> loadProject(SavedProject project) async {
    // 先切到项目所用色卡（旧项目无记录时回退通用卡），
    // toPattern 的色号解析依赖当前色卡。
    BeadPalette.setActive(project.paletteId);
    paletteId = BeadPalette.active.id;
    final p = project.toPattern();
    if (p == null) {
      throw const FormatException('项目数据损坏，无法加载');
    }
    _debounce?.cancel();
    projectId = project.id;
    projectName = project.name;
    createdAt = project.createdAt;
    pattern = p;
    manualEdits
      ..clear()
      ..addAll(project.manualEdits);
    dither = project.dither;
    brightness = project.brightness.toDouble();
    contrast = project.contrast.toDouble();
    colorLimit = project.colorLimit;
    gridWidthCtrl.text = '${project.width}';
    gridHeightCtrl.text = '${project.height}';
    // 已保存项目不含原图像素：重新转换不可用（参数调整需基于原图，
    // 而原图未存储），清空原图信息避免误导。
    _pixels = null;
    _srcWidth = 0;
    _srcHeight = 0;
    _fileName = project.sourceFileName;
    previewImage = null;
    _undoStack.clear();
    _redoStack.clear();
    _currentStroke = null;
    _autoCodes.clear();
    hasUnsavedChanges = false;
    notifyListeners();
  }

  /// 重置为空白编辑器（新建项目前调用）。
  void reset() {
    _debounce?.cancel();
    projectId = null;
    projectName = '';
    createdAt = null;
    pattern = null;
    manualEdits.clear();
    _autoCodes.clear();
    _pixels = null;
    _srcWidth = 0;
    _srcHeight = 0;
    _fileName = null;
    previewImage = null;
    dither = true;
    brightness = 0;
    contrast = 0;
    colorLimit = 0;
    BeadPalette.setActive('default');
    paletteId = 'default';
    gridWidthCtrl.text = '29';
    gridHeightCtrl.text = '29';
    _undoStack.clear();
    _redoStack.clear();
    _currentStroke = null;
    brushCode = null;
    hasUnsavedChanges = false;
    notifyListeners();
  }

  static String _newId() {
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final rand = (DateTime.now().microsecondsSinceEpoch % 46656)
        .toRadixString(36)
        .padLeft(3, '0');
    return 'p_${ts}_$rand';
  }

  @override
  void dispose() {
    _debounce?.cancel();
    gridWidthCtrl.dispose();
    gridHeightCtrl.dispose();
    super.dispose();
  }
}

class _ConvertArgs {
  const _ConvertArgs(this.pixels, this.srcWidth, this.srcHeight, this.options);
  final Uint8List pixels;
  final int srcWidth;
  final int srcHeight;
  final ConvertOptions options;
}

/// 单格编辑记录：颜色从 oldCode 改为 newCode。
class _CellEdit {
  const _CellEdit(this.x, this.y, this.oldCode, this.newCode);

  final int x;
  final int y;
  final String oldCode;
  final String newCode;
}

/// 一笔笔画（一次拖动涂色的所有格子编辑），撤销的最小单位。
class _Stroke {
  final List<_CellEdit> edits = [];

  /// 笔画期间是否有实际改动（快速路径标记）。
  bool dirty = false;
}
