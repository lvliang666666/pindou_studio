import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:printing/printing.dart';

import '../../data/project_model.dart';
import '../../data/project_repository.dart';
import '../../state/editor_state.dart';
import '../../theme/pindou_theme.dart';
import '../../theme/theme_controller.dart';
import '../export_service.dart';
import '../pattern_canvas.dart';
import '../print_service.dart';
import '../settings_dialog.dart';
import '../stitch_dialog.dart';

/// 编辑器页面：参数区 + 图纸画布 + 统计导出区。
///
/// 响应式布局：
/// - 宽屏（>=1100）：三栏（参数 | 画布 | 统计）
/// - 中屏（>=700）：两栏（画布 + 侧面板，参数/统计切换）
/// - 窄屏（手机）：画布全屏 + 底部弹出面板（参数/统计二选一）
class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.state, required this.settings});

  final EditorState state;

  /// 应用设置：设置对话框切换主题/色卡持久化用。
  final AppSettings settings;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  bool _showGrid = true;
  final _widthFocus = FocusNode();
  final _heightFocus = FocusNode();

  /// 用户最后编辑的尺寸框（'w'/'h'）：确认时按它联动另一个框。
  String? _lastSizeField;

  // 滑块拖动中的临时值：拖动过程只刷新滑块，松手才提交到 state 触发转换。
  final _brightnessDrag = ValueNotifier<double?>(null);
  final _contrastDrag = ValueNotifier<double?>(null);
  final _colorLimitDrag = ValueNotifier<double?>(null);

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChanged);
    // 尺寸输入框失焦时确认渲染（回车确认由 onSubmitted 处理）。
    _widthFocus.addListener(_onWidthFocusChanged);
    _heightFocus.addListener(_onHeightFocusChanged);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    _widthFocus.dispose();
    _heightFocus.dispose();
    _brightnessDrag.dispose();
    _contrastDrag.dispose();
    _colorLimitDrag.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    // 转换刚完成：保持遮罩，让画布在本帧（遮罩下）完成重绘，
    // 帧渲染结束后再移除遮罩并刷新统计。
    if (_wasConverting && !widget.state.converting) {
      _hideOverlayNextFrame = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _hideOverlayNextFrame = false;
          _statsPattern = widget.state.pattern;
        });
      });
    } else if (_statsPattern != widget.state.pattern) {
      // 非转换通知（笔画结束/撤销/重做/单格编辑）：pattern 实例已变，
      // 统计面板与导出必须跟上，否则导出的还是转换时的旧图纸。
      // 笔画中的快速路径不换 pattern 实例，不会走到这里。
      _statsPattern = widget.state.pattern;
    }
    _wasConverting = widget.state.converting;
    setState(() {});
  }

  /// 上一帧的 converting 状态（检测 true→false 边沿）。
  bool _wasConverting = false;

  /// 统计面板延迟一帧刷新：转换完成的第一帧只呈现画布（遮罩消失+重绘），
  /// 下一帧再更新右侧统计与颜色列表，避免同帧大重建造成卡顿。
  BeadPattern? _statsPattern;

  /// 遮罩延迟移除：转换完成后画布先在遮罩下完成重绘，
  /// 重绘帧渲染完成后（postFrame）下一帧才移除遮罩——
  /// 用户看到的是"加载动画 → 图纸直接出现"，无中间卡顿帧。
  bool _hideOverlayNextFrame = false;

  void _onWidthFocusChanged() {
    if (!_widthFocus.hasFocus) {
      widget.state.confirmGridSize(fromField: _lastSizeField);
    }
  }

  void _onHeightFocusChanged() {
    if (!_heightFocus.hasFocus) {
      widget.state.confirmGridSize(fromField: _lastSizeField);
    }
  }

  Future<void> _pickImage() async {
    const typeGroup = XTypeGroup(
      label: '图片',
      extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'],
    );
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    try {
      final bytes = await file.readAsBytes();
      await widget.state.loadImage(bytes, file.name);
      // 留存导入历史（尽力而为，失败不影响导入）。
      unawaited(widget.state.repository.recordImport(bytes, file.name));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败：$e')),
        );
      }
    }
  }

  /// 从最近导入历史加载图片。
  Future<void> _loadFromHistory(ImportRecord record) async {
    try {
      final bytes = await record.file.readAsBytes();
      await widget.state.loadImage(bytes, record.fileName);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载失败：$e')),
      );
    }
  }

  /// 多图拼合：对话框内完成转换，结果装入编辑器（保留配方支持改颗粒度重拼）。
  Future<void> _stitchImages() async {
    final result = await showStitchDialog(
      context,
      boardSize: widget.settings.boardSize,
    );
    if (result == null || !mounted) return;
    widget.state.loadPattern(
      result.$1.pattern,
      name: '多图拼合',
      stitchRecipe: result.$2,
    );
  }

  /// 最近导入菜单（参数区「导入图片」旁的下拉入口）。
  Future<void> _showRecentImports() async {
    final records = await widget.state.repository.listImports();
    if (!mounted) return;
    if (records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有导入记录')),
      );
      return;
    }
    final theme = Theme.of(context);
    final picked = await showDialog<ImportRecord>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('最近导入'),
        children: [
          for (final r in records.take(8))
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(r),
              child: ListTile(
                leading: const Icon(Icons.image_outlined),
                title: Text(r.fileName,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(_formatImportDate(r.importedAt),
                    style: theme.textTheme.bodySmall),
                dense: true,
              ),
            ),
        ],
      ),
    );
    if (picked != null) _loadFromHistory(picked);
  }

  static String _formatImportDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return '今天';
    if (diff.inDays == 1) return '昨天';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${dt.year}/${dt.month}/${dt.day}';
  }

  /// 侧面板当前显示内容（中屏/窄屏用）：参数 or 统计。
  _SidePanel _sidePanel = _SidePanel.params;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final pattern = state.pattern;

    return Scaffold(
      appBar: AppBar(
        title: _buildTitle(context, state),
        actions: [
          IconButton(
            tooltip: '撤销 (Ctrl+Z)',
            icon: const Icon(Icons.undo),
            onPressed: state.canUndo ? state.undo : null,
          ),
          IconButton(
            tooltip: '重做 (Ctrl+Y)',
            icon: const Icon(Icons.redo),
            onPressed: state.canRedo ? state.redo : null,
          ),
          IconButton(
            tooltip: '保存项目 (Ctrl+S)',
            icon: state.hasUnsavedChanges
                ? const Icon(Icons.save_outlined)
                : const Icon(Icons.check_circle_outline),
            onPressed: state.pattern == null ? null : _saveProject,
          ),
          PopupMenuButton<String>(
            tooltip: '项目',
            icon: const Icon(Icons.folder_open),
            onSelected: (v) {
              if (v == 'new') _newProject();
              if (v == 'open') _openProjectDialog();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'new',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.add, size: 20),
                  title: Text('新建项目'),
                ),
              ),
              PopupMenuItem(
                value: 'open',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.folder_open, size: 20),
                  title: Text('打开项目…'),
                ),
              ),
            ],
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () =>
                showSettingsDialog(context, widget.settings),
          ),
          const SizedBox(width: 4),
        ],
      ),
        body: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
                state.undo,
            const SingleActivator(LogicalKeyboardKey.keyY, control: true):
                state.redo,
            const SingleActivator(LogicalKeyboardKey.keyZ,
                control: true, shift: true): state.redo,
            const SingleActivator(LogicalKeyboardKey.keyS, control: true):
                _saveProject,
          },
          child: Focus(
            autofocus: true,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                if (width >= 1100) {
                  return _buildThreeColumns(context, state, pattern);
                }
                if (width >= 700) {
                  return _buildTwoColumns(context, state, pattern);
                }
                return _buildNarrow(context, state, pattern);
              },
            ),
          ),
        ),
    );
  }

  /// AppBar 标题：项目名 + 未保存圆点 + 原图信息（宽屏）。
  Widget _buildTitle(BuildContext context, EditorState state) {
    final theme = Theme.of(context);
    final name = state.projectName.isNotEmpty
        ? state.projectName
        : (state.fileName ?? '未命名项目');
    return Row(
      children: [
        Flexible(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (state.hasUnsavedChanges)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (state.fileName != null && state.srcWidth > 0)
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text(
              '${state.fileName}  (${state.srcWidth}x${state.srcHeight})',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  /// 新建项目：有未保存修改时先确认，然后重置编辑器。
  Future<void> _newProject() async {
    final state = widget.state;
    if (state.hasUnsavedChanges) {
      final proceed = await _confirmDiscard('新建将放弃当前未保存的修改，是否继续？');
      if (proceed != true || !mounted) return;
    }
    state.reset();
  }

  /// 打开项目：弹出已保存项目选择列表。
  Future<void> _openProjectDialog() async {
    final state = widget.state;
    if (state.hasUnsavedChanges) {
      final proceed = await _confirmDiscard('打开其他项目将放弃当前未保存的修改，是否继续？');
      if (proceed != true || !mounted) return;
    }
    final project = await showDialog<SavedProject>(
      context: context,
      builder: (context) => _OpenProjectDialog(repository: state.repository),
    );
    if (project == null || !mounted) return;
    try {
      await state.loadProject(project);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开项目失败：$e')),
      );
    }
  }

  /// 放弃修改确认：返回 true 表示用户确认放弃。
  Future<bool?> _confirmDiscard(String message) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('有未保存的修改'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('放弃修改'),
          ),
        ],
      ),
    );
  }

  /// 保存项目（Ctrl+S / AppBar 保存按钮）。
  Future<void> _saveProject() async {
    final state = widget.state;
    if (state.pattern == null) return;
    try {
      await state.save();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存：${state.projectName}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    }
  }

  // ---------- 响应式布局 ----------

  /// 画布区域（三处布局共用）。
  Widget _buildCanvas(BuildContext context, EditorState state) {
    final pattern = state.pattern;
    final canvasColors = context.canvasColors;
    return Stack(
      children: [
        // 画布始终挂载：转换完成后先在遮罩下完成重绘，
        // 重绘帧结束后才移除遮罩（见 _hideOverlayNextFrame）。
        Container(
          color: canvasColors.canvasBg,
          padding: const EdgeInsets.all(16),
          child: PatternCanvas(
            pattern: pattern,
            colors: canvasColors,
            showGrid: _showGrid,
            boardSize: widget.settings.boardSize,
            brushCode: state.brushCode,
            onPaintCell: (x, y) => _paintCell(state, x, y),
            onEraseCell: (x, y) => state.eraseCell(x, y),
            onStrokeStart: state.beginStroke,
            onStrokeEnd: state.endStroke,
            onCellTap: (x, y) => _showColorPicker(state, x, y),
          ),
        ),
        if (state.converting || _hideOverlayNextFrame)
          Positioned.fill(
            child: ColoredBox(
              color: canvasColors.overlayMask,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 44,
                      height: 44,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                    const SizedBox(height: 14),
                    Text('正在生成图纸…',
                        style: TextStyle(
                            fontSize: 15, color: canvasColors.overlayText)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 宽屏：三栏（参数 | 画布 | 统计）。
  Widget _buildThreeColumns(
      BuildContext context, EditorState state, BeadPattern? pattern) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildParamsPanel(context, state),
        const VerticalDivider(width: 1),
        Expanded(child: _buildCanvas(context, state)),
        const VerticalDivider(width: 1),
        Builder(builder: (context) {
          // 统计面板与画布分帧：转换完成帧只重绘画布（遮罩下），
          // 遮罩移除帧才更新统计（见 _onStateChanged 边沿处理）。
          return _buildStatsPanel(context, state, _statsPattern);
        }),
      ],
    );
  }

  /// 中屏：两栏（画布 + 侧面板切换）。
  Widget _buildTwoColumns(
      BuildContext context, EditorState state, BeadPattern? pattern) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _buildCanvas(context, state)),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 300,
          child: Column(
            children: [
              // 参数/统计切换标签。
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: SegmentedButton<_SidePanel>(
                  segments: const [
                    ButtonSegment(
                      value: _SidePanel.params,
                      icon: Icon(Icons.tune),
                      label: Text('参数'),
                    ),
                    ButtonSegment(
                      value: _SidePanel.stats,
                      icon: Icon(Icons.bar_chart),
                      label: Text('统计'),
                    ),
                  ],
                  selected: {_sidePanel},
                  onSelectionChanged: (s) =>
                      setState(() => _sidePanel = s.first),
                ),
              ),
              Expanded(
                child: _sidePanel == _SidePanel.params
                    ? _buildParamsPanel(context, state)
                    : Builder(builder: (context) {
                        return _buildStatsPanel(context, state, _statsPattern);
                      }),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 窄屏（手机）：画布全屏 + 底部工具条弹出面板。
  Widget _buildNarrow(
      BuildContext context, EditorState state, BeadPattern? pattern) {
    return Stack(
      children: [
        Positioned.fill(child: _buildCanvas(context, state)),
        // 底部工具条：弹出参数/统计面板。
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  elevation: 4,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton.icon(
                          onPressed: () =>
                              _showSideSheet(context, state, _SidePanel.params),
                          icon: const Icon(Icons.tune, size: 18),
                          label: const Text('参数'),
                        ),
                        TextButton.icon(
                          onPressed: () =>
                              _showSideSheet(context, state, _SidePanel.stats),
                          icon: const Icon(Icons.bar_chart, size: 18),
                          label: const Text('统计'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 窄屏底部弹出面板（参数/统计）。
  void _showSideSheet(
      BuildContext context, EditorState state, _SidePanel panel) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.92,
        minChildSize: 0.4,
        builder: (context, scrollController) =>
            panel == _SidePanel.params
                ? SingleChildScrollView(
                    controller: scrollController,
                    child: _buildParamsPanel(context, state),
                  )
                : _buildStatsPanel(context, state, _statsPattern),
      ),
    );
  }
  // ---------- 左侧参数区 ----------

  Widget _buildParamsPanel(BuildContext context, EditorState state) {
    return SizedBox(
      width: 280,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: state.converting ? null : _pickImage,
              icon: const Icon(Icons.image),
              label: const Text('导入图片'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: state.converting ? null : _showRecentImports,
              icon: const Icon(Icons.history, size: 18),
              label: const Text('最近导入'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: state.converting ? null : _stitchImages,
              icon: const Icon(Icons.grid_view, size: 18),
              label: const Text('多图拼合'),
            ),
            if (state.previewImage != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image(
                  image: state.previewImage!,
                  height: 140,
                  fit: BoxFit.contain,
                  alignment: Alignment.center,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text('拼豆色卡', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: state.paletteId,
              isDense: true,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              items: [
                for (final set in BeadPalette.ordered)
                  DropdownMenuItem(
                    value: set.id,
                    child: Text(
                      '${set.displayName} · ${set.colors.length}色',
                      style: const TextStyle(fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null && v != state.paletteId) {
                  setState(() => state.setPalette(v));
                }
              },
            ),
            const SizedBox(height: 16),
            Text(
              state.isBoardMode
                  ? '一板多图（${widget.settings.boardSize} x ${widget.settings.boardSize}）'
                  : state.isStitched
                      ? '单张颗粒度（豆）'
                      : '图纸尺寸（豆数）',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (state.isBoardMode)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '总尺寸固定为底板，子图自动分布；'
                  '底板尺寸在设置页修改，点「确认尺寸并生成」重拼',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else if (state.isStitched)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '拼合项目：宽/高填单张最长边，确认后重新拼合',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: state.gridWidthCtrl,
                    focusNode: _widthFocus,
                    keyboardType: TextInputType.number,
                    onChanged: (t) {
                      state.setGridWidth(t);
                      _lastSizeField = 'w';
                    },
                    onSubmitted: (_) => state.confirmGridSize(fromField: 'w'),
                    decoration: const InputDecoration(
                      labelText: '宽',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('x'),
                ),
                Expanded(
                  child: TextField(
                    controller: state.gridHeightCtrl,
                    focusNode: _heightFocus,
                    keyboardType: TextInputType.number,
                    onChanged: (t) {
                      state.setGridHeight(t);
                      _lastSizeField = 'h';
                    },
                    onSubmitted: (_) => state.confirmGridSize(fromField: 'h'),
                    decoration: const InputDecoration(
                      labelText: '高',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => state.confirmGridSize(fromField: _lastSizeField),
              icon: const Icon(Icons.check),
              label: const Text('确认尺寸并生成'),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('锁定宽高比'),
              subtitle: const Text('确认时按原图比例算高', style: TextStyle(fontSize: 12)),
              value: state.lockRatio,
              onChanged: (v) => setState(() => state.setLockRatio(v)),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                for (final preset in const [29, 58, 87])
                  ActionChip(
                    label: Text('$preset'),
                    onPressed: () {
                      state.gridWidthCtrl.text = '$preset';
                      state.gridHeightCtrl.text = '$preset';
                      state.confirmGridSize();
                    },
                  ),
              ],
            ),
            const Divider(height: 32),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('抖动（Floyd-Steinberg）'),
              subtitle: const Text('渐变过渡更自然', style: TextStyle(fontSize: 12)),
              value: state.dither,
              onChanged: (v) => setState(() => state.setDither(v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('显示网格线'),
              value: _showGrid,
              onChanged: (v) => setState(() => _showGrid = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('画笔模式'),
              subtitle: Text(
                state.brushCode == null
                    ? '开启后从右侧颜色列表选画笔'
                    : '当前画笔：${state.brushCode}（右键擦除）',
                style: const TextStyle(fontSize: 12),
              ),
              value: state.brushCode != null,
              onChanged: (v) => setState(() {
                if (v) {
                  final counts = state.pattern?.counts;
                  state.setBrush(
                      counts != null && counts.isNotEmpty
                          ? counts.first.color.code
                          : null);
                  if (counts == null || counts.isEmpty) state.setBrush(null);
                } else {
                  state.setBrush(null);
                }
              }),
            ),
            const Divider(height: 32),
            ValueListenableBuilder<double?>(
              valueListenable: _brightnessDrag,
              builder: (context, drag, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('亮度 ${(drag ?? state.brightness).round()}',
                      style: Theme.of(context).textTheme.titleSmall),
                  Slider(
                    value: drag ?? state.brightness,
                    min: -100,
                    max: 100,
                    divisions: 200,
                    label: '${(drag ?? state.brightness).round()}',
                    onChanged: (v) => _brightnessDrag.value = v,
                    onChangeEnd: (v) {
                      _brightnessDrag.value = null;
                      state.setBrightness(v);
                    },
                  ),
                ],
              ),
            ),
            ValueListenableBuilder<double?>(
              valueListenable: _contrastDrag,
              builder: (context, drag, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('对比度 ${(drag ?? state.contrast).round()}',
                      style: Theme.of(context).textTheme.titleSmall),
                  Slider(
                    value: drag ?? state.contrast,
                    min: -100,
                    max: 100,
                    divisions: 200,
                    label: '${(drag ?? state.contrast).round()}',
                    onChanged: (v) => _contrastDrag.value = v,
                    onChangeEnd: (v) {
                      _contrastDrag.value = null;
                      state.setContrast(v);
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 32),
            ValueListenableBuilder<double?>(
              valueListenable: _colorLimitDrag,
              builder: (context, drag, _) {
                final v = drag ?? state.colorLimit.toDouble();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('颜色数量上限：${v.round() == 0 ? '不限' : v.round()}',
                        style: Theme.of(context).textTheme.titleSmall),
                    Slider(
                      value: v,
                      min: 0,
                      max: 40,
                      divisions: 40,
                      label: v.round() == 0 ? '不限' : '${v.round()}',
                      onChanged: (nv) => _colorLimitDrag.value = nv,
                      onChangeEnd: (nv) {
                        _colorLimitDrag.value = null;
                        state.setColorLimit(nv.round());
                      },
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 右侧统计导出区 ----------

  Widget _buildStatsPanel(BuildContext context, EditorState state, BeadPattern? pattern) {
    return SizedBox(
      width: 300,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pattern != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      _statRow('图纸尺寸', '${pattern.width} x ${pattern.height}', context),
                      _statRow('总豆数', '${pattern.totalBeads}', context),
                      _statRow('颜色数', '${pattern.colorCount}', context),
                      _statRow('底板数',
                          '${pattern.boardCount(boardSize: widget.settings.boardSize)} (${widget.settings.boardSize}x${widget.settings.boardSize})',
                          context),
                    ],
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    // 导出始终用 state.pattern（最新图纸，含手动编辑），
                    // 不用延迟刷新的 _statsPattern。
                    onPressed: state.pattern == null
                        ? null
                        : () => _exportPng(state.pattern!),
                    icon: const Icon(Icons.image_outlined),
                    label: const Text('导出图纸 PNG'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: state.pattern == null
                        ? null
                        : () => _exportCsv(state.pattern!),
                    icon: const Icon(Icons.table_view),
                    label: const Text('导出豆数 CSV'),
                  ),
                ),
              ],
            ),
          ),
          if (pattern != null &&
              (pattern.width > widget.settings.boardSize ||
                  pattern.height > widget.settings.boardSize))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: OutlinedButton.icon(
                onPressed: state.pattern == null
                    ? null
                    : () => _exportBoardPngs(state.pattern!),
                icon: const Icon(Icons.dashboard_customize),
                label: Text(
                    '分板导出 PNG (${pattern.boardCount(boardSize: widget.settings.boardSize)} 块)',
                    style: const TextStyle(fontSize: 13)),
              ),
            ),
          if (pattern != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: state.pattern == null
                          ? null
                          : () => _printPattern(state.pattern!),
                      icon: const Icon(Icons.print_outlined),
                      label: const Text('打印',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: state.pattern == null
                          ? null
                          : () => _exportPdf(state.pattern!),
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: const Text('导出 PDF',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ),
                ],
              ),
            ),
          if (state.manualEdits.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: OutlinedButton.icon(
                onPressed: () => state.clearManualEdits(),
                icon: const Icon(Icons.undo, size: 18),
                label: Text('撤销全部手动编辑 (${state.manualEdits.length})',
                    style: const TextStyle(fontSize: 13)),
              ),
            ),
          Expanded(
            child: pattern == null
                ? Center(
                    child: Text('暂无数据',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.outline)))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: pattern.counts.length,
                    itemExtent: 44, // 固定行高：布局零测量，长列表滚动更稳。
                    itemBuilder: (context, i) {
                      final bc = pattern.counts[i];
                      final isBrush = state.brushCode == bc.color.code;
                      return ListTile(
                        dense: true,
                        selected: isBrush,
                        selectedTileColor: Theme.of(context)
                            .colorScheme.primaryContainer
                            .withValues(alpha: 0.4),
                        leading: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: Color(bc.color.argb),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isBrush
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.outline,
                              width: isBrush ? 2.5 : 1,
                            ),
                          ),
                        ),
                        title: Text('${bc.color.code} ${bc.color.name}',
                            style: const TextStyle(fontSize: 13)),
                        trailing: Text('${bc.count}',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.bold)),
                        onTap: () => setState(() {
                          state.setBrush(isBrush ? null : bc.color.code);
                        }),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _statRow(String label, String value, BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 13, color: Theme.of(context).colorScheme.outline)),
          Text(value,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // ---------- 手动编辑 ----------

  /// 画笔涂色：有画笔时直接涂，无画笔时弹选色框。
  /// 返回 (是否有变化, 新内容)（供画布叠加层即时显示）。
  (bool, BeadColor?) _paintCell(EditorState state, int x, int y) {
    final code = state.brushCode;
    if (code == null) {
      _showColorPicker(state, x, y);
      return (false, null);
    }
    final bead = BeadPalette.byCode[code];
    if (bead == null) return (false, null);
    return state.paintCell(x, y, bead);
  }

  /// 弹出选色面板：已用颜色优先，其余按色系分组展示。
  /// 返回空串 = 擦成空格（不放豆）；null = 取消。
  Future<void> _showColorPicker(EditorState state, int x, int y) async {
    final pattern = state.pattern;
    if (pattern == null) return;
    final current = pattern.cellAt(x, y);
    final currentDesc = current == null
        ? '空格（不放豆）'
        : '${current.code} ${current.name}';

    final selected = await showDialog<Object>(
      context: context,
      builder: (context) => _ColorPickerDialog(
        title: '替换 ($x, $y) 颜色，当前：$currentDesc',
        usedColors: [for (final bc in pattern.counts) bc.color],
        currentCode: current?.code ?? '',
        allowEmpty: true,
      ),
    );
    if (selected == null || !mounted) return;
    if (selected is String && selected.isEmpty) {
      // 擦成空格。
      state.eraseToEmpty(x, y);
      return;
    }
    if (selected is BeadColor) {
      state.editCell(x, y, selected);
    }
  }

  // ---------- 导出 ----------

  Future<void> _exportPng(BeadPattern pattern) async {
    final bytes = await ExportService.renderPatternPng(
        pattern, boardSize: widget.settings.boardSize);
    final suggestedName = 'pindou_${pattern.width}x${pattern.height}.png';
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PNG 图片', extensions: ['png'])
      ],
    );
    if (location == null) return;
    // Windows 保存对话框可能返回无扩展名路径，强制补 .png。
    var path = location.path;
    if (!path.toLowerCase().endsWith('.png')) {
      path = '$path.png';
    }
    final file = XFile.fromData(bytes,
        mimeType: 'image/png', name: suggestedName);
    await file.saveTo(path);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存：$path')),
      );
    }
  }

  /// 按 29x29 底板切分并导出多张 PNG 到所选文件夹。
  Future<void> _exportBoardPngs(BeadPattern pattern) async {
    final directoryPath = await getDirectoryPath(
      confirmButtonText: '选择保存文件夹',
    );
    if (directoryPath == null) return;
    try {
      final boards = ExportService.splitByBoards(pattern,
          boardSize: widget.settings.boardSize);
      for (final (bx, by, sub) in boards) {
        final bytes = await ExportService.renderPatternPng(sub,
            boardSize: widget.settings.boardSize);
        final name =
            'board_r${by + 1}_c${bx + 1}_${sub.width}x${sub.height}.png';
        final file = XFile.fromData(bytes, mimeType: 'image/png', name: name);
        await file.saveTo('$directoryPath${Platform.pathSeparator}$name');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存 ${boards.length} 张分板图到：$directoryPath')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败：$e')),
        );
      }
    }
  }

  Future<void> _exportCsv(BeadPattern pattern) async {
    final csv = ExportService.buildCsv(pattern);
    final suggestedName = 'pindou_beads_${pattern.width}x${pattern.height}.csv';
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'CSV', extensions: ['csv'])
      ],
    );
    if (location == null) return;
    // Windows 保存对话框可能返回无扩展名路径，强制补 .csv。
    var path = location.path;
    if (!path.toLowerCase().endsWith('.csv')) {
      path = '$path.csv';
    }
    // 写 UTF-8 BOM，方便 Excel 直接打开中文不乱码。
    final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...csv.codeUnits]);
    final file = XFile.fromData(bytes, mimeType: 'text/csv', name: suggestedName);
    await file.saveTo(path);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存：$path')),
      );
    }
  }

  /// 打印：调起系统打印对话框（printing 包内置 PDF 预览）。
  Future<void> _printPattern(BeadPattern pattern) async {
    final state = widget.state;
    final name = state.projectName.isNotEmpty
        ? state.projectName
        : (state.fileName ?? '拼豆图纸');
    try {
      await Printing.layoutPdf(
        onLayout: (format) =>
            PrintService.buildPdf(pattern,
                projectName: name, boardSize: widget.settings.boardSize),
        name: name,
        format: const PdfPageFormat(595, 842, marginAll: 0),
        usePrinterSettings: true,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打印失败：$e')),
      );
    }
  }

  /// 导出 PDF 文件（A4 分板排版，与打印同一生成逻辑）。
  Future<void> _exportPdf(BeadPattern pattern) async {
    final state = widget.state;
    final name = state.projectName.isNotEmpty
        ? state.projectName
        : (state.fileName ?? '拼豆图纸');
    final suggestedName = 'pindou_${pattern.width}x${pattern.height}.pdf';
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PDF', extensions: ['pdf'])
      ],
    );
    if (location == null) return;
    var path = location.path;
    if (!path.toLowerCase().endsWith('.pdf')) {
      path = '$path.pdf';
    }
    try {
      final bytes =
          await PrintService.buildPdf(pattern,
              projectName: name, boardSize: widget.settings.boardSize);
      final file = XFile.fromData(bytes,
          mimeType: 'application/pdf', name: suggestedName);
      await file.saveTo(path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存：$path')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }
}


/// 选色对话框：已用颜色 + 全色卡（按色系分组）。
/// [allowEmpty] 时顶部提供「擦成空格」选项（返回空字符串）。
class _ColorPickerDialog extends StatelessWidget {
  const _ColorPickerDialog({
    required this.title,
    required this.usedColors,
    required this.currentCode,
    this.allowEmpty = false,
  });

  final String title;
  final List<BeadColor> usedColors;
  final String currentCode;
  final bool allowEmpty;

  @override
  Widget build(BuildContext context) {
    final unusedGroups = <String, List<BeadColor>>{};
    final usedCodes = usedColors.map((c) => c.code).toSet();
    BeadPalette.groups.forEach((group, colors) {
      final rest = colors.where((c) => !usedCodes.contains(c.code)).toList();
      if (rest.isNotEmpty) unusedGroups[group] = rest;
    });

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  children: [
                    if (allowEmpty && currentCode.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).pop(''),
                          icon: const Icon(Icons.grid_off, size: 18),
                          label: const Text('擦成空格（不放豆）'),
                        ),
                      ),
                    _section(context, '当前图纸使用的颜色', usedColors),
                    for (final entry in unusedGroups.entries)
                      _section(context, entry.key, entry.value),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String name, List<BeadColor> colors) {
    if (colors.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(name,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.primary)),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in colors)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => Navigator.of(context).pop(c),
                child: Container(
                  width: 86,
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: c.code == currentCode
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outlineVariant,
                      width: c.code == currentCode ? 2 : 1,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      Container(
                        height: 34,
                        decoration: BoxDecoration(
                          color: Color(c.argb),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                              color: Theme.of(context).colorScheme.outlineVariant),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(c.code,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold)),
                      Text(c.name,
                          style: const TextStyle(fontSize: 10),
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 侧面板内容类型。
enum _SidePanel { params, stats }

/// 打开项目对话框：缩略图网格列出已保存项目，支持重命名/复制/删除。
/// 选中项目返回完整数据（null = 取消）。
class _OpenProjectDialog extends StatefulWidget {
  const _OpenProjectDialog({required this.repository});

  final ProjectRepository repository;

  @override
  State<_OpenProjectDialog> createState() => _OpenProjectDialogState();
}

class _OpenProjectDialogState extends State<_OpenProjectDialog> {
  List<ProjectSummary>? _projects;
  String? _error;

  /// 缩略图缓存（id -> PNG 字节），列表加载后异步补齐。
  final _thumbs = <String, Uint8List?>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final projects = await widget.repository.listProjects();
      if (!mounted) return;
      setState(() => _projects = projects);
      for (final p in projects) {
        if (p.hasThumbnail) {
          final bytes = await widget.repository.loadThumbnail(p.id);
          if (!mounted) return;
          setState(() => _thumbs[p.id] = bytes);
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _open(ProjectSummary summary) async {
    try {
      final project = await widget.repository.loadProject(summary.id);
      if (!mounted) return;
      if (project == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('项目不存在或已损坏')),
        );
        _load();
        return;
      }
      Navigator.of(context).pop(project);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开失败：$e')),
      );
    }
  }

  Future<void> _rename(ProjectSummary summary) async {
    final controller = TextEditingController(text: summary.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名项目'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '项目名',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (newName == null || newName.trim().isEmpty || !mounted) return;
    await widget.repository.renameProject(summary.id, newName.trim());
    _load();
  }

  Future<void> _duplicate(ProjectSummary summary) async {
    final newId = await widget.repository.duplicateProject(summary.id);
    if (!mounted) return;
    if (newId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('复制失败：项目不存在')),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制：${summary.name} 副本')),
    );
    _load();
  }

  Future<void> _delete(ProjectSummary summary) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除项目'),
        content: Text('确定删除「${summary.name}」吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.repository.deleteProject(summary.id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('打开项目'),
      content: SizedBox(
        width: 560,
        height: 480,
        child: _buildBody(theme),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Colors.redAccent),
            const SizedBox(height: 10),
            Text('读取项目列表失败：$_error'),
            const SizedBox(height: 10),
            FilledButton.tonal(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final projects = _projects;
    if (projects == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (projects.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_outlined,
                size: 48,
                color: theme.colorScheme.outline.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            const Text('还没有已保存的项目'),
            const SizedBox(height: 4),
            Text('编辑器里按 Ctrl+S 即可保存当前图纸',
                style: theme.textTheme.bodySmall),
          ],
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 170,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.82,
      ),
      itemCount: projects.length,
      itemBuilder: (context, i) => _buildCard(theme, projects[i]),
    );
  }

  Widget _buildCard(ThemeData theme, ProjectSummary s) {
    final thumb = _thumbs[s.id];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 缩略图区。
            Expanded(
              child: Container(
                color: theme.colorScheme.surfaceContainerHighest,
                alignment: Alignment.center,
                child: thumb != null
                    ? Image.memory(
                        thumb,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      )
                    : const Icon(Icons.grid_on_outlined, size: 32),
              ),
            ),
            // 信息区。
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          '${s.width}x${s.height} · ${s.colorCount}色 · ${_formatDate(s.updatedAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  // 操作菜单。
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 20),
                    onSelected: (v) {
                      if (v == 'open') _open(s);
                      if (v == 'rename') _rename(s);
                      if (v == 'duplicate') _duplicate(s);
                      if (v == 'delete') _delete(s);
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'open',
                        child: ListTile(
                          leading: Icon(Icons.open_in_new),
                          title: Text('打开'),
                          dense: true,
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'rename',
                        child: ListTile(
                          leading: Icon(Icons.edit_outlined),
                          title: Text('重命名'),
                          dense: true,
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'duplicate',
                        child: ListTile(
                          leading: Icon(Icons.copy_outlined),
                          title: Text('复制'),
                          dense: true,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          leading: Icon(Icons.delete_outline,
                              color: theme.colorScheme.error),
                          title: Text('删除',
                              style:
                                  TextStyle(color: theme.colorScheme.error)),
                          dense: true,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return '今天';
    if (diff.inDays == 1) return '昨天';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${dt.year}/${dt.month}/${dt.day}';
  }
}
