import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/converter.dart';
import '../core/palette.dart';

/// 图纸画布：绘制拼豆网格、色块、色号，支持缩放、平移与画笔涂色。
class PatternCanvas extends StatefulWidget {
  const PatternCanvas({
    super.key,
    required this.pattern,
    this.showGrid = true,
    this.showRuler = true,
    this.onCellTap,
    this.brushCode,
    this.onPaintCell,
    this.onEraseCell,
    this.onStrokeStart,
    this.onStrokeEnd,
  });

  final BeadPattern? pattern;
  final bool showGrid;

  /// 是否显示行号/列号标尺与底板分界线。
  final bool showRuler;

  /// 点击格子回调（未启用画笔时），参数为格子坐标 (x, y)。
  final void Function(int x, int y)? onCellTap;

  /// 画笔色号；非 null 时启用画笔模式（拖动涂色，右键擦除）。
  final String? brushCode;

  /// 画笔涂到某格（笔画过程中连续回调）。
  /// 返回实际应用的颜色（格子无变化为 null），供叠加层即时显示。
  final BeadColor? Function(int x, int y)? onPaintCell;

  /// 右键擦除某格（恢复自动转换色）。返回恢复后的颜色，无编辑记录为 null。
  final BeadColor? Function(int x, int y)? onEraseCell;

  /// 笔画开始/结束（用于把一次拖动合并为一步撤销）。
  final VoidCallback? onStrokeStart;
  final VoidCallback? onStrokeEnd;

  @override
  State<PatternCanvas> createState() => _PatternCanvasState();
}

class _PatternCanvasState extends State<PatternCanvas> {
  final TransformationController _transform = TransformationController();

  /// 当前缩放比例（供工具条百分比显示）。
  final ValueNotifier<double> _scale = ValueNotifier<double>(1);

  /// 预渲染图纸位图（含色块+网格线+外框，不含标尺）。
  /// 缩放/平移时 GPU 只需变换这一张纹理，大图也流畅。
  ui.Image? _rasterImage;

  /// 位图对应的 pattern 与参数（判断缓存是否有效）。
  BeadPattern? _rasterPattern;
  bool _rasterShowGrid = true;
  bool _rasterShowRuler = true;

  /// 正在光栅化（避免重复提交）。
  bool _rasterizing = false;

  // 画笔状态。
  bool _painting = false;
  int? _lastCellX;
  int? _lastCellY;
  bool _erasing = false;
  int _activeButtons = 0;

  /// 叠加层版本号：涂色时递增，触发画布重绘（不重建子树）。
  final ValueNotifier<int> _overlayVersion = ValueNotifier<int>(0);

  /// 本笔画中变化的格子与最新颜色（叠加层绘制内容）。
  final List<(int, int, BeadColor)> _dirtyCells = [];

  /// 待增量光栅化的脏格子（笔画结束到光栅化完成期间持有）。
  /// 光栅化时只重绘这些格子（叠加到旧位图上），避免全图重绘。
  List<(int, int, BeadColor)>? _pendingDirtyCells;

  void _onTransformChanged() {
    // 只更新缩放百分比显示（ValueListenableBuilder 局部刷新，不重建子树）。
    _scale.value = _transform.value.getMaxScaleOnAxis();
  }

  /// 缩放控制：围绕视口中心缩放。
  void _zoomBy(double factor) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final center = box.size.center(Offset.zero);
    final current = _transform.value.clone();
    final scale = current.getMaxScaleOnAxis();
    final newScale = (scale * factor).clamp(0.2, 8.0);
    final effective = newScale / scale;
    current
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(effective, effective, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
    _transform.value = current;
  }

  /// 适应窗口。
  void _fitToView(BeadPattern p) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final vpW = box.size.width - 32;
    final vpH = box.size.height - 32;
    if (vpW <= 0 || vpH <= 0) return;
    final cell = (vpW / p.width).clamp(1.0, vpH / p.height);
    final scale = cell / _baseCell;
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        (box.size.width - p.width * cell) / 2,
        (box.size.height - p.height * cell) / 2,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
    _scale.value = scale;
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChanged);
    _transform.dispose();
    _rasterImage?.dispose();
    super.dispose();
  }


  @override
  void didUpdateWidget(PatternCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    final p = widget.pattern;
    if (p != null && (oldWidget.pattern == null ||
        p.width != oldWidget.pattern!.width ||
        p.height != oldWidget.pattern!.height)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitToView(p));
    }
    // 图纸/显示选项变化：使位图缓存失效并重新光栅化。
    // 笔画中跳过：涂色由叠加层即时显示，笔画结束（onStrokeEnd）后统一重光栅化。
    // 延迟到帧渲染完成后执行，避免与状态层重建同帧叠加。
    if (!_painting &&
        (p != _rasterPattern ||
            widget.showGrid != _rasterShowGrid ||
            widget.showRuler != _rasterShowRuler)) {
      _scheduleRasterizeAfterFrame();
    }
  }

  /// 将图纸光栅化为位图（异步光栅化，不阻塞 UI）。
  /// 完成后触发一次重绘，paint 只 drawImage，缩放平移由 GPU 变换纹理。
  ///
  /// [_pendingDirtyCells] 非空时走**增量光栅化**：旧位图 + 只重绘脏格子，
  /// 绘制指令从"全图 run-length + 网格线 + 标尺"缩减为
  /// "1 次 drawImage + N 个脏格子矩形"，笔画结束的收尾开销大幅下降。
  Future<void> _scheduleRasterize() async {
    if (_rasterizing) return;
    _rasterizing = true;
    final p = widget.pattern;
    if (p == null) {
      _rasterizing = false;
      return;
    }
    // 增量模式仅当：有脏格子、旧位图存在、旧位图对应同一 pattern 尺寸
    // 且显示选项未变（否则内容结构不同，必须全量）。
    final dirty = _pendingDirtyCells;
    final canIncremental = dirty != null &&
        dirty.isNotEmpty &&
        _rasterImage != null &&
        _rasterPattern != null &&
        _rasterPattern!.width == p.width &&
        _rasterPattern!.height == p.height &&
        _rasterShowGrid == widget.showGrid &&
        _rasterShowRuler == widget.showRuler;
    _pendingDirtyCells = null;
    try {
      // 2x 超采样：放大到 200% 仍清晰。
      const ss = 2.0;
      final w = (p.width * _baseCell * ss).round();
      final h = (p.height * _baseCell * ss).round();
      if (w <= 0 || h <= 0) return;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
      canvas.scale(ss);
      if (canIncremental) {
        // 增量：旧位图打底，脏格子覆盖。
        // 注意 canvas 已 scale(ss)：所有坐标都是 1x 逻辑坐标，
        // 目标矩形必须用逻辑尺寸（w/ss = p.width * _baseCell），
        // 若直接用 w/h 会被 scale 再放大 ss 倍，旧图只画进左上角
        // 1/ss 区域——表现为"每画一笔图片缩小一圈，最后消失"。
        final src = _rasterImage!;
        final logicalW = w / ss;
        final logicalH = h / ss;
        canvas.drawImageRect(
          src,
          Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
          Rect.fromLTWH(0, 0, logicalW, logicalH),
          Paint()..filterQuality = FilterQuality.none,
        );
        final fill = Paint()..style = PaintingStyle.fill;
        // 色块向外扩半个线宽：网格线（半透明黑）居中于格子边界，
        // 一半落在邻居格子内——不扩边的话，新线会叠加在旧位图的
        // 旧线上导致边界变深（擦除后尤其明显）。扩出去的半像素
        // 随后被新画的线覆盖，视觉无损失。
        const bleed = 0.5;
        for (final (x, y, bead) in dirty) {
          fill.color = Color(bead.argb);
          canvas.drawRect(
            Rect.fromLTWH(
              x * _baseCell - bleed,
              y * _baseCell - bleed,
              _baseCell + bleed * 2,
              _baseCell + bleed * 2,
            ),
            fill,
          );
        }
        // 脏格子覆盖了旧位图的网格线，在其上补画。
        // 关键：网格线居中于格线（线宽一半在格子内、一半在邻居内），
        // 脏格子色块（含 bleed 0.5px）只盖掉自己一侧的半条线，
        // 邻居一侧的半条线仍在旧位图上。若只补"格子边缘"这半条，
        // 叠加后线宽只有一半且位置偏移——10 格加深线表现为"断线/变浅"。
        // 因此补画必须以格线为中心画完整线宽（向两侧各扩半线宽），
        // 与全量绘制（drawPath 居中描边）完全一致。
        if (widget.showGrid) {
          final cell = _baseCell;
          // 收集脏格子涉及的格线（以格线坐标标识，非格子边缘）：
          // 竖线 gx（0..width），横线 gy（0..height），去重。
          final vLines = <int>{};
          final hLines = <int>{};
          for (final (x, y, _) in dirty) {
            vLines.add(x); // 左格线
            vLines.add(x + 1); // 右格线
            hLines.add(y); // 上格线
            hLines.add(y + 1); // 下格线
          }
          // 细线：所有格线（与全量 gridPath 一致：0..width/height 全画）。
          // 加深线：x%10==0 的竖线、y%10==0 的横线（与全量 majorPath 一致）。
          final thin = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Colors.black26;
          final thick = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.black45;
          for (final gx in vLines) {
            final isMajor = gx % 10 == 0;
            final x = gx * cell;
            canvas.drawLine(
                Offset(x, 0), Offset(x, p.height * cell), isMajor ? thick : thin);
          }
          for (final gy in hLines) {
            final isMajor = gy % 10 == 0;
            final y = gy * cell;
            canvas.drawLine(
                Offset(0, y), Offset(p.width * cell, y), isMajor ? thick : thin);
          }
        }
      } else {
        _PatternPainter(
          pattern: p,
          showGrid: widget.showGrid,
          showRuler: widget.showRuler,
          cell: _baseCell,
        ).paint(canvas, Size(w.toDouble(), h.toDouble()));
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(w, h);
      if (!mounted) {
        image.dispose();
        return;
      }
      final old = _rasterImage;
      setState(() {
        _rasterImage = image;
        _rasterPattern = p;
        _rasterShowGrid = widget.showGrid;
        _rasterShowRuler = widget.showRuler;
      });
      old?.dispose();
    } finally {
      _rasterizing = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransformChanged);
    final p = widget.pattern;
    if (p != null) {
      _scheduleRasterize();
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitToView(p));
    }
  }

  /// 屏幕坐标 -> 格子坐标。
  /// 除法结果可能因浮点误差略小于整数（如 47.9999999），加 epsilon 修正。
  (int, int)? _cellAt(Offset localPos) {
    final p = widget.pattern;
    if (p == null) return null;
    const eps = 1e-6;
    final x = (localPos.dx / _baseCell + eps).floor();
    final y = (localPos.dy / _baseCell + eps).floor();
    if (x < 0 || x >= p.width || y < 0 || y >= p.height) return null;
    return (x, y);
  }

  // ===== 右键擦除（raw pointer）：pan 手势只响应左键，右键需自行处理 =====

  /// 右键按下：开始擦除笔画。
  void _handleRightDown(PointerDownEvent e) {
    if (widget.brushCode == null) return;
    final cell = _cellAt(e.localPosition);
    if (cell == null) return;
    widget.onStrokeStart?.call();
    _painting = true;
    _erasing = true;
    _dirtyCells.clear();
    _lastCellX = cell.$1;
    _lastCellY = cell.$2;
    _paintAt(cell.$1, cell.$2);
  }

  /// 右键拖动：连续擦除（Bresenham 补插）。
  void _handleRightMove(PointerMoveEvent e) {
    if (!_painting || !_erasing) return;
    final cell = _cellAt(e.localPosition);
    if (cell == null) return;
    final lx = _lastCellX, ly = _lastCellY;
    if (lx != null && ly != null) {
      _paintLine(lx, ly, cell.$1, cell.$2);
    } else {
      _paintAt(cell.$1, cell.$2);
    }
    _lastCellX = cell.$1;
    _lastCellY = cell.$2;
  }

  /// 右键抬起：结束笔画并增量光栅化。
  void _handleRightUp(PointerEvent e) {
    if (_painting && _erasing) {
      _painting = false;
      _erasing = false;
      _lastCellX = null;
      _lastCellY = null;
      widget.onStrokeEnd?.call();
      _pendingDirtyCells = List.of(_dirtyCells);
      _dirtyCells.clear();
      _overlayVersion.value++;
      _scheduleRasterizeAfterFrame();
    }
  }

  void _handlePanStart(DragStartDetails details) {
    final cell = _cellAt(details.localPosition);
    if (cell == null) return;
    widget.onStrokeStart?.call();
    _painting = true;
    _erasing = _activeButtons == kSecondaryMouseButton;
    _dirtyCells.clear();
    _lastCellX = cell.$1;
    _lastCellY = cell.$2;
    _paintAt(cell.$1, cell.$2);
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    if (!_painting) return;
    final cell = _cellAt(details.localPosition);
    if (cell == null) return;
    final lx = _lastCellX, ly = _lastCellY;
    if (lx != null && ly != null) {
      _paintLine(lx, ly, cell.$1, cell.$2);
    } else {
      _paintAt(cell.$1, cell.$2);
    }
    _lastCellX = cell.$1;
    _lastCellY = cell.$2;
  }

  void _handlePanEnd(DragEndDetails details) {
    if (_painting) {
      _painting = false;
      _lastCellX = null;
      _lastCellY = null;
      widget.onStrokeEnd?.call();
      // 脏格子转交增量光栅化（只重绘这些格子，不全图重绘）。
      _pendingDirtyCells = List.of(_dirtyCells);
      _dirtyCells.clear();
      _overlayVersion.value++;
      // 笔画结束：pattern 已重建（新实例）。重光栅化推迟到本帧渲染完成后，
      // 避免与 endStroke 的重建/全页刷新同帧叠加造成松手瞬间卡顿。
      _scheduleRasterizeAfterFrame();
    }
  }

  /// 帧渲染完成后再光栅化：把重活挪出当前帧。
  void _scheduleRasterizeAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleRasterize();
    });
  }

  void _paintAt(int x, int y) {
    // 回调同步更新 pattern.cells 并返回实际应用的颜色；
    // 无变化（同色重复涂/未编辑过的擦除）返回 null，不记脏格子。
    final BeadColor? applied;
    if (_erasing) {
      applied = widget.onEraseCell?.call(x, y);
    } else {
      applied = widget.onPaintCell?.call(x, y);
    }
    if (applied == null) return;
    _dirtyCells.add((x, y, applied));
    _overlayVersion.value++;
  }

  /// Bresenham 直线补插，快速拖动时不跳格。
  void _paintLine(int x0, int y0, int x1, int y1) {
    int dx = (x1 - x0).abs(), dy = -(y1 - y0).abs();
    int sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    while (true) {
      _paintAt(x0, y0);
      if (x0 == x1 && y0 == y1) break;
      final e2 = 2 * err;
      if (e2 >= dy) {
        err += dy;
        x0 += sx;
      }
      if (e2 <= dx) {
        err += dx;
        y0 += sy;
      }
    }
  }

  /// 基准单元尺寸（逻辑像素/豆），缩放基于它计算。
  static const double _baseCell = 24;

  @override
  Widget build(BuildContext context) {
    final pattern = widget.pattern;
    if (pattern == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.grid_off, size: 64, color: Colors.grey),
            SizedBox(height: 12),
            Text('请先导入图片并生成图纸',
                style: TextStyle(color: Colors.grey, fontSize: 16)),
          ],
        ),
      );
    }

    final brushActive = widget.brushCode != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        InteractiveViewer(
          transformationController: _transform,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          minScale: 0.2,
          maxScale: 8.0,
          constrained: false,
          panEnabled: !brushActive, // 画笔模式下左键用于涂色，滚轮/双指仍可缩放。
          scaleEnabled: true,
          child: Listener(
            onPointerDown: (e) => _activeButtons = e.buttons,
            onPointerUp: (e) => _activeButtons = 0,
            onPointerCancel: (e) => _activeButtons = 0,
            child: GestureDetector(
            onTapUp: brushActive
                ? null
                : (widget.onCellTap == null
                    ? null
                    : (details) {
                        final cell = _cellAt(details.localPosition);
                        if (cell != null) widget.onCellTap!(cell.$1, cell.$2);
                      }),
            onPanStart: brushActive ? _handlePanStart : null,
            onPanUpdate: brushActive ? _handlePanUpdate : null,
            onPanEnd: brushActive ? _handlePanEnd : null,
            // 右键擦除与左键涂色同路径：按下拖动 = 连续擦除（pan 手势
            // 不区分按键，_handlePanStart 按 _activeButtons 判定擦除模式），
            // 单击一格 = 一次零距离 pan，同样走 begin/erase/end。
              child: SizedBox(
                width: pattern.width * _baseCell,
                height: pattern.height * _baseCell,
                // 内层 Listener：右键擦除走 raw pointer（pan 手势只响应
                // 左键）。放在 SizedBox 内层保证 localPosition 与 _cellAt
                // 同一坐标系。
                child: Listener(
                  onPointerDown: (e) {
                    if (e.buttons == kSecondaryMouseButton) {
                      _handleRightDown(e);
                    }
                  },
                  onPointerMove: (e) {
                    if (e.buttons == kSecondaryMouseButton) {
                      _handleRightMove(e);
                    }
                  },
                  onPointerUp: _handleRightUp,
                  onPointerCancel: _handleRightUp,
                  // RepaintBoundary：图纸内容缓存为独立图层，
                  // 缩放/平移时仅做合成变换，不触发重绘。
                  child: RepaintBoundary(
                  child: ValueListenableBuilder<int>(
                    valueListenable: _overlayVersion,
                    builder: (context, version, _) => CustomPaint(
                      painter: _RasterPatternPainter(
                        image: _rasterImage,
                        fallback: _rasterImage == null
                            ? _PatternPainter(
                                pattern: pattern,
                                showGrid: widget.showGrid,
                                showRuler: widget.showRuler,
                                cell: _baseCell,
                              )
                            : null,
                        cell: _baseCell,
                      ),
                      // 前景叠加层：笔画中涂过的格子用矢量即时绘制，
                      // 位图保持旧内容不重光栅化（松手后统一更新）。
                      foregroundPainter: _painting && _dirtyCells.isNotEmpty
                          ? _StrokeOverlayPainter(
                              dirtyCells: _dirtyCells,
                              cell: _baseCell,
                              version: version,
                            )
                          : null,
                    ),
                  ),
                ),
                ),
              ),
            ),
          ),
        ),
        // 右下角缩放工具条。
        Positioned(
          right: 12,
          bottom: 12,
          child: Card(
            elevation: 3,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '缩小',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.zoom_out),
                    onPressed: () => _zoomBy(1 / 1.25),
                  ),
                  ValueListenableBuilder<double>(
                    valueListenable: _scale,
                    builder: (context, scale, _) => Text(
                      '${(scale * 100).round()}%',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    tooltip: '放大',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.zoom_in),
                    onPressed: () => _zoomBy(1.25),
                  ),
                  IconButton(
                    tooltip: '适应窗口',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.fit_screen),
                    onPressed: () => _fitToView(pattern),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 笔画叠加层：绘制"位图内容与当前 pattern 不同的格子"。
/// 笔画中 pattern.cells 已更新（可变副本），但位图仍是旧内容——
/// State 侧维护脏格子集合，这里只重绘脏格子（通常 1~10 个），开销极小。
class _StrokeOverlayPainter extends CustomPainter {
  _StrokeOverlayPainter({
    required this.dirtyCells,
    required this.cell,
    required this.version,
  });

  /// 本笔画中变化的格子与最新颜色。
  final List<(int, int, BeadColor)> dirtyCells;
  final double cell;

  /// 版本号：每次涂色递增，驱动重绘。
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..style = PaintingStyle.fill;
    for (final (x, y, bead) in dirtyCells) {
      fill.color = Color(bead.argb);
      canvas.drawRect(
        Rect.fromLTWH(x * cell, y * cell, cell, cell),
        fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StrokeOverlayPainter oldDelegate) {
    return oldDelegate.version != version ||
        oldDelegate.dirtyCells.length != dirtyCells.length;
  }
}

/// 位图绘制器：图纸已光栅化为 ui.Image 后，paint 只做一次 drawImageRect，
/// 缩放/平移时 GPU 仅变换单张纹理，大图也流畅。
/// 位图未就绪（首帧/重新光栅化中）时回退到矢量绘制。
class _RasterPatternPainter extends CustomPainter {
  _RasterPatternPainter({
    required this.image,
    required this.fallback,
    required this.cell,
  });

  final ui.Image? image;
  final _PatternPainter? fallback;
  final double cell;

  @override
  void paint(Canvas canvas, Size size) {
    final img = image;
    if (img != null) {
      // 位图按 2x 超采样光栅化，绘制目标为 1x 逻辑尺寸。
      final w = img.width / 2.0;
      final h = img.height / 2.0;
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromLTWH(0, 0, w, h),
        Paint()..filterQuality = FilterQuality.medium,
      );
      return;
    }
    fallback?.paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _RasterPatternPainter oldDelegate) {
    if (oldDelegate.image != image) return true;
    final f = fallback;
    final of = oldDelegate.fallback;
    if ((f == null) != (of == null)) return true;
    if (f == null || of == null) return false;
    return f.pattern != of.pattern ||
        f.showGrid != of.showGrid ||
        f.showRuler != of.showRuler ||
        f.cell != of.cell;
  }
}

class _PatternPainter extends CustomPainter {
  _PatternPainter({
    required this.pattern,
    required this.showGrid,
    required this.showRuler,
    required this.cell,
  });

  final BeadPattern pattern;
  final bool showGrid;
  final bool showRuler;
  final double cell;

  /// 标尺文字跨帧缓存：(文本, 格子尺寸) -> 已排版 TextPainter。
  static final Map<(String, double), TextPainter> _rulerTextCache = {};

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()..style = PaintingStyle.fill;

    // 绘制全部格子。RepaintBoundary 将结果缓存为图层：
    // 内容不变时（缩放/平移）不再重绘，交互由合成器完成，因此这里
    // 的一次性全量绘制不会影响缩放平移流畅度。
    // 注意：不能按视口裁剪——缓存层必须包含完整图纸，否则缩放后缺块。
    const x0 = 0;
    final x1 = pattern.width;
    const y0 = 0;
    final y1 = pattern.height;

    for (int y = y0; y < y1; y++) {
      // 同色连续格子合并为一个矩形，减少 drawRect 调用。
      int runStart = x0;
      BeadColor? runBead;
      void flushRun(int endX) {
        if (runBead == null) return;
        fillPaint.color = Color(runBead.argb);
        canvas.drawRect(
          Rect.fromLTWH(runStart * cell, y * cell, (endX - runStart) * cell, cell),
          fillPaint,
        );
      }

      for (int x = x0; x < x1; x++) {
        final bead = pattern.cellAt(x, y);
        if (bead != runBead) {
          flushRun(x);
          runStart = x;
          runBead = bead;
        }
      }
      flushRun(x1);
    }

    // 网格线：合并为两条 Path，一次 drawPath 完成。
    if (showGrid) {
      final gridPath = Path()
        ..addRect(Rect.fromLTWH(0, 0, pattern.width * cell, pattern.height * cell));
      for (int x = x0; x <= x1; x++) {
        gridPath.moveTo(x * cell, y0 * cell);
        gridPath.lineTo(x * cell, y1 * cell);
      }
      for (int y = y0; y <= y1; y++) {
        gridPath.moveTo(x0 * cell, y * cell);
        gridPath.lineTo(x1 * cell, y * cell);
      }
      canvas.drawPath(
        gridPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.black26,
      );
      // 每 10 格加深线，方便对照。
      final majorPath = Path();
      for (int x = (x0 ~/ 10) * 10; x <= x1; x += 10) {
        majorPath.moveTo(x * cell, y0 * cell);
        majorPath.lineTo(x * cell, y1 * cell);
      }
      for (int y = (y0 ~/ 10) * 10; y <= y1; y += 10) {
        majorPath.moveTo(x0 * cell, y * cell);
        majorPath.lineTo(x1 * cell, y * cell);
      }
      canvas.drawPath(
        majorPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.black45,
      );
    }

    // 外边框。
    canvas.drawRect(
      Rect.fromLTWH(0, 0, pattern.width * cell, pattern.height * cell),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.black87,
    );

    // 行号/列号标尺（每 5 格标注）与 29 格底板分界线。
    if (showRuler && cell >= 10) {
      const rulerStep = 5;
      const boardSize = 29;
      final labelStyle = TextStyle(
        color: Colors.black54,
        fontSize: cell * 0.42,
        fontWeight: FontWeight.w600,
      );

      // 标尺文字缓存：同字号同文本只排版一次（跨帧复用）。
      final rulerCache = _rulerTextCache;
      void drawLabel(String text, Offset center) {
        final key = (text, cell);
        var tp = rulerCache[key];
        if (tp == null) {
          tp = TextPainter(textDirection: TextDirection.ltr)
            ..text = TextSpan(text: text, style: labelStyle)
            ..layout();
          rulerCache[key] = tp;
        }
        tp.paint(
          canvas,
          Offset(
            center.dx - tp.width / 2,
            center.dy - tp.height / 2,
          ),
        );
      }

      // 列号（顶部）。
      for (int x = rulerStep; x <= pattern.width; x += rulerStep) {
        drawLabel('$x', Offset(x * cell, -cell * 0.7));
      }
      // 行号（左侧）。
      for (int y = rulerStep; y <= pattern.height; y += rulerStep) {
        drawLabel('$y', Offset(-cell * 0.7, y * cell));
      }

      // 29 格底板分界虚线（跳过 0 与最外边界）。
      final dashPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.deepOrange.withValues(alpha: 0.65);
      for (int x = boardSize; x < pattern.width; x += boardSize) {
        _drawDashedLine(
          canvas, dashPaint,
          Offset(x * cell, 0), Offset(x * cell, pattern.height * cell),
        );
      }
      for (int y = boardSize; y < pattern.height; y += boardSize) {
        _drawDashedLine(
          canvas, dashPaint,
          Offset(0, y * cell), Offset(pattern.width * cell, y * cell),
        );
      }
    }
  }

  /// 绘制竖直/水平虚线。
  static void _drawDashedLine(Canvas canvas, Paint paint, Offset start, Offset end) {
    const dashLen = 6.0;
    const gapLen = 4.0;
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final len = (dx * dx + dy * dy);
    if (len == 0) return;
    final unit = Offset(dx, dy) / len;
    var dist = 0.0;
    final total = len;
    while (dist < total) {
      final segEnd = (dist + dashLen).clamp(0.0, total);
      canvas.drawLine(
        start + unit * dist,
        start + unit * segEnd,
        paint,
      );
      dist = segEnd + gapLen;
    }
  }

  @override
  bool shouldRepaint(covariant _PatternPainter oldDelegate) {
    return oldDelegate.pattern != pattern ||
        oldDelegate.showGrid != showGrid ||
        oldDelegate.showRuler != showRuler ||
        oldDelegate.cell != cell;
  }
}
