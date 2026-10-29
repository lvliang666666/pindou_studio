import 'package:flutter/material.dart';

import 'state/editor_state.dart';
import 'theme/theme_controller.dart';
import 'ui/editor/editor_page.dart';

void main() {
  runApp(const PindouStudioApp());
}

/// 应用根：持有应用设置（主题/色卡），打开即编辑器（单页直入，无图库首页）。
class PindouStudioApp extends StatefulWidget {
  const PindouStudioApp({super.key});

  @override
  State<PindouStudioApp> createState() => _PindouStudioAppState();
}

class _PindouStudioAppState extends State<PindouStudioApp> {
  late final AppSettings _settings;

  /// 编辑器状态引用（initState 后非空）：底板尺寸变化时同步。
  EditorState? _editorState;

  /// 底板尺寸变化 → 同步默认图纸尺寸（空编辑器/新建项目跟随），
  /// 并同步到已存在的编辑器状态（底板显示/超出缩回立即生效）。
  void _onSettingsChanged() {
    EditorState.syncDefaultGridSize(_settings.boardSize);
    _editorState?.syncBoardSize(_settings.boardSize);
  }

  @override
  void initState() {
    super.initState();
    _settings = AppSettings();
    // 异步读取持久化设置：首帧先以默认渲染，读完后通知重建。
    // 底板尺寸同步为默认图纸尺寸（空编辑器/新建项目用）。
    _settings.load().then((_) {
      EditorState.syncDefaultGridSize(_settings.boardSize);
    });
    // 底板尺寸变化时同步到编辑器状态（底板显示/超出缩回用）。
    _settings.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) => MaterialApp(
        title: '拼豆工作室',
        debugShowCheckedModeBanner: false,
        theme: _settings.theme.themeData,
        home: _EditorHome(
          settings: _settings,
          onEditorState: (state) => _editorState = state,
        ),
      ),
    );
  }
}

/// 编辑器宿主：EditorState 在应用级持有，生命周期与进程一致；
/// 项目的新建/打开/保存收敛到编辑器 AppBar（保存按钮 + 项目菜单），
/// 主题与色卡设置入口同样在 AppBar（齿轮图标）。
class _EditorHome extends StatefulWidget {
  const _EditorHome({required this.settings, this.onEditorState});

  final AppSettings settings;

  /// 编辑器状态创建后回调（应用根持有引用，设置变化时同步）。
  final void Function(EditorState state)? onEditorState;

  @override
  State<_EditorHome> createState() => _EditorHomeState();
}

class _EditorHomeState extends State<_EditorHome> {
  late final EditorState _editorState;

  @override
  void initState() {
    super.initState();
    _editorState = EditorState();
    // 把编辑器状态暴露给应用根：设置页改底板尺寸时
    // syncBoardSize 立即同步（底板显示/超出缩回即时生效）。
    widget.onEditorState?.call(_editorState);
  }

  @override
  void dispose() {
    _editorState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return EditorPage(
      state: _editorState,
      settings: widget.settings,
    );
  }
}
