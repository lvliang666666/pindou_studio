import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/project_repository.dart';
import '../../data/project_model.dart';

/// 项目库首页：展示已保存项目，支持新建/打开/重命名/删除。
///
/// 设计原则：简洁为主。卡片网格 + 底部悬浮新建按钮，
/// 窄屏自动减少列数（手机端友好）。
class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.repository,
    required this.onCreateProject,
    required this.onOpenProject,
  });

  final ProjectRepository repository;

  /// 新建项目（进入编辑器并导入图片）。
  final VoidCallback onCreateProject;

  /// 打开已有项目（进入编辑器）。
  final void Function(SavedProject project) onOpenProject;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<ProjectSummary>? _projects;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final projects = await widget.repository.listProjects();
      if (!mounted) return;
      setState(() {
        _projects = projects;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }
  /// 打开项目：读取完整数据后回调。
  Future<void> _open(ProjectSummary summary) async {
    try {
      final project = await widget.repository.loadProject(summary.id);
      if (!mounted) return;
      if (project == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('项目不存在或已损坏')),
        );
        await _refresh();
        return;
      }
      widget.onOpenProject(project);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开失败：$e')),
      );
    }
  }

  Future<void> _renameProject(ProjectSummary summary) async {
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
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == summary.name) return;
    await widget.repository.renameProject(summary.id, newName);
    await _refresh();
  }

  Future<void> _deleteProject(ProjectSummary summary) async {
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
    if (confirmed != true) return;
    await widget.repository.deleteProject(summary.id);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('拼豆工作室'),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: widget.onCreateProject,
        icon: const Icon(Icons.add),
        label: const Text('新建项目'),
      ),
      body: _buildBody(theme),
    );
  }
  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
            const SizedBox(height: 12),
            Text('加载项目失败：$_error'),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: _refresh, child: const Text('重试')),
          ],
        ),
      );
    }
    final projects = _projects ?? const [];
    if (projects.isEmpty) {
      return _buildEmpty(theme);
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 响应式列数：窄屏 2 列，宽屏最多 5 列。
          final width = constraints.maxWidth;
          final columns = width < 480
              ? 2
              : width < 720
                  ? 3
                  : width < 1000
                      ? 4
                      : 5;
          const spacing = 12.0;
          final cardWidth = (width - spacing * (columns - 1) - 32) / columns;
          final imageHeight = (cardWidth * 0.8).clamp(90.0, 220.0);
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              childAspectRatio: cardWidth / (imageHeight + 76),
            ),
            itemCount: projects.length,
            itemBuilder: (context, i) => _ProjectCard(
              summary: projects[i],
              repository: widget.repository,
              onTap: () => _open(projects[i]),
              onRename: () => _renameProject(projects[i]),
              onDelete: () => _deleteProject(projects[i]),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dashboard_customize_outlined,
              size: 72, color: theme.colorScheme.primary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          Text('还没有项目', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('导入一张图片，生成你的第一份拼豆图纸',
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: widget.onCreateProject,
            icon: const Icon(Icons.add),
            label: const Text('新建项目'),
          ),
        ],
      ),
    );
  }
}
/// 单个项目卡片：缩略图 + 名称 + 元信息 + 操作菜单。
class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.summary,
    required this.repository,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final ProjectSummary summary;
  final ProjectRepository repository;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _Thumbnail(
                projectId: summary.id,
                repository: repository,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          summary.name,
                          style: theme.textTheme.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      _CardMenu(
                        onRename: onRename,
                        onDelete: onDelete,
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${summary.width}x${summary.height} · ${summary.colorCount} 色 · ${_formatDate(summary.updatedAt)}',
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
/// 卡片缩略图：从仓库读取 PNG；无缩略图时显示占位。
class _Thumbnail extends StatefulWidget {
  const _Thumbnail({
    required this.projectId,
    required this.repository,
  });

  final String projectId;
  final ProjectRepository repository;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  Uint8List? _bytes;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await widget.repository.loadThumbnail(widget.projectId);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(
          child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_bytes == null) {
      return Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(Icons.grid_on,
            size: 36,
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
      );
    }
    return Image.memory(
      _bytes!,
      fit: BoxFit.cover,
      gaplessPlayback: true,
    );
  }
}

/// 卡片右上角菜单：重命名 / 删除。
class _CardMenu extends StatelessWidget {
  const _CardMenu({required this.onRename, required this.onDelete});

  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 20),
      splashRadius: 20,
      onSelected: (v) {
        if (v == 'rename') onRename();
        if (v == 'delete') onDelete();
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: 'rename',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined, size: 20),
            title: Text('重命名'),
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline, size: 20),
            title: Text('删除'),
          ),
        ),
      ],
    );
  }
}