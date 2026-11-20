/// DSH 工作台 —— 文件管理器页（阶段④）。
///
/// 功能：浏览盘符/目录、打开文本预览、新建文件夹/文件、重命名、
/// 删除、上传小文件、下载（票据链接）。
///
/// ⚠️ UI 规范沿用阶段②的决定：**不硬凑 Kotlin 版的像素**，
/// 只保证配色令牌与 Mica 背景一致。用 Flutter 自己的布局习惯。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/fs_api.dart';
import 'icons.dart';
import 'theme_toggle.dart';
import 'theme.dart';

class FileBrowserPage extends StatefulWidget {
  final FsApi fs;
  final bool dark;

  /// 打开时直接进这个目录（对话里点路径进来时用）。
  /// 空串 = 老行为：从盘符列表开始。
  final String initialPath;

  const FileBrowserPage({
    super.key,
    required this.fs,
    required this.dark,
    this.initialPath = '',
  });

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  FsListing? _listing;
  String _path = '';
  bool _loading = true;
  String? _error;
  bool _showHidden = false;

  @override
  void initState() {
    super.initState();
    // 从对话里点路径进来时直奔目标目录；否则还是盘符列表
    _load(widget.initialPath);
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final (r, listing) = await widget.fs.list(path, showHidden: _showHidden);
    if (!mounted) return;
    if (!r.ok || listing == null) {
      setState(() {
        _loading = false;
        _error = r.friendlyError;
      });
      return;
    }
    setState(() {
      _loading = false;
      _listing = listing;
      _path = path;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(msg.trim().isEmpty ? '完成' : msg),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /* ---------------- 操作 ---------------- */

  Future<void> _openEntry(FsEntry e) async {
    if (e.isDir) {
      await _load(e.path);
      return;
    }
    await _previewText(e);
  }

  Future<void> _previewText(FsEntry e) async {
    final (r, text) = await widget.fs.readText(e.path);
    if (!mounted) return;
    if (!r.ok || text == null) {
      // 二进制文件宿主会明确报 binary-file，这里如实转达
      _toast('打不开：${r.friendlyError}');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _PreviewDialog(
        title: e.name,
        text: text,
        dark: widget.dark,
        onSave: (newText) async {
          final w = await widget.fs.writeText(e.path, newText);
          if (!mounted) return;
          _toast(w.ok ? '已保存' : '保存失败：${w.friendlyError}');
        },
      ),
    );
  }

  Future<void> _mkdir() async {
    final name = await _askText('新建文件夹', '文件夹名');
    if (name == null || name.isEmpty) return;
    final sep = _listing?.sep ?? '\\';
    final r = await widget.fs.mkdir(_join(_path, name, sep));
    _toast(r.ok ? '已创建' : '创建失败：${r.friendlyError}');
    if (r.ok) await _load(_path);
  }

  Future<void> _newFile() async {
    final name = await _askText('新建文件', '文件名（含扩展名）');
    if (name == null || name.isEmpty) return;
    final sep = _listing?.sep ?? '\\';
    final r = await widget.fs.touch(_join(_path, name, sep));
    _toast(r.ok ? '已创建' : '创建失败：${r.friendlyError}');
    if (r.ok) await _load(_path);
  }

  Future<void> _rename(FsEntry e) async {
    final name = await _askText('重命名', '新名字', initial: e.name);
    if (name == null || name.isEmpty || name == e.name) return;
    final sep = _listing?.sep ?? '\\';
    final r = await widget.fs.move(e.path, _join(_path, name, sep));
    _toast(r.ok ? '已重命名' : '重命名失败：${r.friendlyError}');
    if (r.ok) await _load(_path);
  }

  Future<void> _delete(FsEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final c = DshColors.of(widget.dark);
        return AlertDialog(
          backgroundColor: c.sheetFill,
          title: Text('删除', style: TextStyle(color: c.textPrimary)),
          content: Text(
            '确定删除「${e.name}」？\n${e.isDir ? "目录会连同内容一起删掉。" : ""}',
            style: TextStyle(color: c.textSecondary, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('删除', style: TextStyle(color: c.danger)),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    final r = await widget.fs.remove(e.path, recursive: e.isDir);
    _toast(r.ok ? '已删除' : '删除失败：${r.friendlyError}');
    if (r.ok) await _load(_path);
  }

  Future<void> _download(FsEntry e) async {
    final (r, url) = await widget.fs.ticket(e.path);
    if (!mounted) return;
    if (!r.ok || url == null) {
      _toast('取下载链接失败：${r.friendlyError}');
      return;
    }
    // 票据 URL 已带 ticket，复制给用户 —— 手机上没有系统下载器可用，
    // 复制链接是最实际的交付方式。
    await Clipboard.setData(ClipboardData(text: url));
    _toast('下载链接已复制（60 秒内有效，一次性）');
  }

  /// 上传文件。
  ///
  /// ⚠️ 三个必须处理的点（照 Kotlin 版 16.4③ 的教训）：
  ///
  ///  1. **先查大小再读**。整文件 `readBytes()` 会把 20MB 全塞进内存，
  ///     叠上 base64 的 4/3 膨胀就是 ~27MB 峰值 —— 低端机直接 OOM。
  ///     OOM 是 `Error` 不是 `Exception`，只 catch Exception 接不住。
  ///  2. **超过 20MB 直接拒绝**并说清原因，不要让它传到一半失败。
  ///  3. **失败要报出来**，不能静默吞掉（Kotlin 版曾经失败还显示「上传完成 0/1」）。
  Future<void> _upload() async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        withData: false,
        // 同 scan_page.dart 的说明：file_picker 默认 allowCompression=true，
        // 选到图片会走 compressImage 并在后台线程抛 content URI 验证异常，
        // Dart 侧接不住、进程直接被杀。上传不需要压缩，直接关掉。
        allowCompression: false,
      );
    } catch (e) {
      _toast('打开文件选择器失败：$e');
      return;
    }
    if (picked == null || picked.files.isEmpty) return;

    final f = picked.files.first;
    final size = f.size;
    if (size > FsApi.maxUploadBytes) {
      _toast('文件 ${formatBytes(size)}，超过 20MB 上限 —— 请在电脑上操作');
      return;
    }
    if (f.path == null) {
      _toast('拿不到文件路径');
      return;
    }

    if (!mounted) return;
    _toast('上传中 ${formatBytes(size)}…');

    try {
      final bytes = await File(f.path!).readAsBytes();
      /*
       * 上传目标目录：当前所在目录。
       *
       * 在「盘符列表」这一层时 `_path` 是空的，但上传必须有一个具体目录 ——
       * 这时候拒绝上传比猜一个更诚实（用户不会想在 C 盘根目录里凭空多出文件）。
       */
      if (_path.isEmpty) {
        _toast('请先进到某个目录再上传');
        return;
      }
      final r = await widget.fs.upload(dir: _path, name: f.name, bytes: bytes);
      if (!mounted) return;
      if (r.ok) {
        _toast('已上传 ${f.name}');
        await _load(_path);
      } else {
        _toast('上传失败：${r.friendlyError}');
      }
    } catch (e) {
      // OOM 也是 Throwable，这里用 catch-all 保证不闪退
      if (!mounted) return;
      _toast('上传失败：$e');
    }
  }

  /// 下载到本地：**交给系统下载器**（浏览器 / DownloadManager）。
  ///
  /// 这是老版本（Kotlin）的做法，也是用户说的「老版本下载速度很快」的原因：
  /// Kotlin 版根本没有在 App 里搬字节，而是先换一次性票据，再
  /// `Intent.ACTION_VIEW` 把 URL 丢给系统 —— 平台下载器有自己的连接池、
  /// 后台队列和断点续传，比在 Flutter 里单流拉快得多，还不占界面。
  ///
  /// 只有系统里打不开浏览器时才回落到应用内流式下载（[_saveInApp]）。
  Future<void> _saveToLocal(FsEntry e) async {
    final (r, url) = await widget.fs.ticket(e.path);
    if (!mounted) return;
    if (!r.ok || url == null) {
      _toast('取下载链接失败：${r.friendlyError}');
      return;
    }

    final uri = Uri.tryParse(url);
    var handoff = false;
    if (uri != null) {
      try {
        handoff = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        handoff = false;
      }
    }

    if (!mounted) return;
    if (handoff) {
      _toast('已交给系统下载器，浏览器里能看到进度');
      return;
    }
    // 没有浏览器可用：退回应用内下载（慢一点，但能落地）
    _toast('没有可用的浏览器，改用应用内下载');
    await _saveInApp(e);
  }

  /// 应用内流式下载（兜底）。
  ///
  /// 旧实现是 `downloadBytes` + `writeAsBytesSync`，两个坑：
  ///   1. 36 MB 的 APK 整块进内存；
  ///   2. 用的是全局 `receiveTimeout = 60s` —— 公网隧道实测 41 秒，
  ///      手机 4G 更慢，一超时就抛 DioException，而 `friendlyError`
  ///      把网络层错误统一说成「手机和电脑不在同一个网络」（误导用户）。
  ///
  /// 现在：`downloadToFile` 让 Dio 直接往目标路径流式写，超时放宽到 10 分钟，
  /// 并显示百分比进度；失败会删掉半截文件。
  Future<void> _saveInApp(FsEntry e) async {
    // 目标目录：公共 Downloads（免权限，见踩坑文档 6.6）
    final safe = e.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    String? target;
    for (final dir in ['/storage/emulated/0/Download', '/sdcard/Download']) {
      try {
        final d = Directory(dir);
        if (!d.existsSync()) d.createSync(recursive: true);
        target = '$dir/${stamp}_$safe';
        break;
      } catch (_) {
        // 换下一个候选目录
      }
    }
    if (target == null) {
      _toast('手机上没有可写的 Download 目录');
      return;
    }

    final progress = ValueNotifier<double>(0);
    var dialogOpen = true;
    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          final c = DshColors.of(widget.dark);
          return Dialog(
            backgroundColor: c.sheetFill,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '下载中',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${e.name}（${formatBytes(e.size)}）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: c.textTertiary),
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<double>(
                    valueListenable: progress,
                    builder: (_, v, __) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: v <= 0 ? null : v,
                            minHeight: 5,
                            backgroundColor: c.stroke,
                            color: c.accent,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          v <= 0
                              ? '连接中…'
                              : '${(v * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: c.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ).whenComplete(() => dialogOpen = false);
    }

    final r = await widget.fs.downloadToFile(
      path: e.path,
      savePath: target,
      onProgress: (got, total) {
        if (total > 0) progress.value = got / total;
      },
    );

    if (dialogOpen && mounted) Navigator.of(context).maybePop();
    progress.dispose();
    if (!mounted) return;

    if (!r.ok) {
      try {
        final f = File(target);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      _toast('下载失败：${r.friendlyError}');
      return;
    }
    _toast('已保存到 $target');
  }

  Future<String?> _askText(String title, String hint, {String initial = ''}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = DshColors.of(widget.dark);
        return AlertDialog(
          backgroundColor: c.sheetFill,
          title: Text(title, style: TextStyle(color: c.textPrimary)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: TextStyle(color: c.textPrimary),
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  /// 拼路径。用宿主给的 `sep`，别假设是 `/`。
  ///
  /// ⚠️ **不要去掉末尾的分隔符**（阶段④实测踩到）。
  ///
  /// 早先写成「先把末尾 `\` 去掉再拼」，于是 `F:\` + `x.txt` 得到
  /// `F:\x.txt`，宿主 `fs.move` 内部会先 `mkdir(dirname(to))` ——
  /// `dirname('F:\\x.txt')` 是 `F:\`，**对盘符根执行 mkdir 在 Windows 上
  /// 直接 EPERM**：
  ///
  ///     EPERM: operation not permitted, mkdir 'F:\'
  ///
  /// 表现是「重命名对话框关了，但文件没改名」。
  ///
  /// 保留末尾分隔符就没问题：`F:\` + `\` + `x.txt` 会得到 `F:\\x.txt`，
  /// 而 `dirname` 仍然是 `F:\`……所以真正要防的是重复分隔符。
  /// 正确做法：末尾有分隔符就不再补，只补名字。
  static String _join(String dir, String name, String sep) {
    if (dir.isEmpty) return name;
    final hasSep = dir.endsWith(sep) || dir.endsWith('/') || dir.endsWith('\\');
    return hasSep ? '$dir$name' : '$dir$sep$name';
  }

  /* ---------------- 渲染 ---------------- */

  @override
  Widget build(BuildContext context) {
    final c = DshColors.of(widget.dark);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SizedBox.expand(
        child: MicaBackdrop(
          dark: widget.dark,
          child: SafeArea(
            child: Column(
              children: [
                _buildBar(c),
                Expanded(child: _buildBody(c)),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: _loading
          ? null
          : FloatingActionButton(
              backgroundColor: c.accent,
              foregroundColor: c.onAccent,
              onPressed: _showCreateMenu,
              child: DshIcon(DshGlyph.plus, size: 22, color: c.onAccent),
            ),
    );
  }

  void _showCreateMenu() {
    final c = DshColors.of(widget.dark);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.sheetFill,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              titleAlignment: ListTileTitleAlignment.center,
              leading: DshIcon(DshGlyph.folder, size: 20, color: c.textPrimary),
              title: Text('新建文件夹', style: TextStyle(color: c.textPrimary)),
              onTap: () {
                Navigator.pop(ctx);
                _mkdir();
              },
            ),
            ListTile(
              titleAlignment: ListTileTitleAlignment.center,
              leading: DshIcon(
                DshGlyph.fileText,
                size: 20,
                color: c.textPrimary,
              ),
              title: Text('新建文件', style: TextStyle(color: c.textPrimary)),
              onTap: () {
                Navigator.pop(ctx);
                _newFile();
              },
            ),
            ListTile(
              titleAlignment: ListTileTitleAlignment.center,
              leading: DshIcon(DshGlyph.plus, size: 20, color: c.textPrimary),
              title: Text('上传文件', style: TextStyle(color: c.textPrimary)),
              subtitle: Text(
                '上限 20MB',
                style: TextStyle(fontSize: 11.5, color: c.textTertiary),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _upload();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBar(DshColors c) {
    final sep = _listing?.sep ?? '\\';
    final atRoot = _path.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 10, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: DshIcon(DshGlyph.back, size: 20, color: c.textPrimary),
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: const EdgeInsets.all(8),
                onPressed: () {
                  if (atRoot) {
                    Navigator.of(context).pop();
                  } else {
                    _load(_listing?.parent ?? '');
                  }
                },
              ),
              Expanded(
                child: Text(
                  atRoot ? '文件（盘符）' : _path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: c.textPrimary,
                  ),
                ),
              ),
              // 每个页面都能切主题
              ThemeToggleButton(color: c.textPrimary),
              IconButton(
                tooltip: _showHidden ? '隐藏 .开头的项' : '显示隐藏项',
                icon: DshIcon(
                  DshGlyph.eye,
                  size: 20,
                  color: _showHidden ? c.accent : c.textSecondary,
                ),
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: const EdgeInsets.all(8),
                onPressed: () {
                  setState(() => _showHidden = !_showHidden);
                  _load(_path);
                },
              ),
              IconButton(
                tooltip: '刷新',
                icon: DshIcon(
                  DshGlyph.refresh,
                  size: 20,
                  color: c.textSecondary,
                ),
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: const EdgeInsets.all(8),
                onPressed: () => _load(_path),
              ),
            ],
          ),
          if (_listing != null && _listing!.truncated)
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 4),
              child: Text(
                '目录太大，只显示了前 ${_listing!.entries.length} 项'
                '${sep.isEmpty ? '' : ''}',
                style: TextStyle(fontSize: 11, color: c.textTertiary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(DshColors c) {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: c.accent));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DshIcon(DshGlyph.info, size: 32, color: c.danger),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: () => _load(_path),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final entries = [...?_listing?.entries];
    if (entries.isEmpty) {
      return Center(
        child: Text(
          '这里是空的',
          style: TextStyle(color: c.textTertiary, fontSize: 12.5),
        ),
      );
    }

    // 目录在前、文件在后；同类按名字排（和资源管理器的习惯一致）
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return RefreshIndicator(
      color: c.accent,
      onRefresh: () => _load(_path),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 80),
        itemCount: entries.length,
        itemBuilder: (context, i) => _row(c, entries[i]),
      ),
    );
  }

  Widget _row(DshColors c, FsEntry e) {
    final icon = e.isDir ? DshGlyph.folder : _iconForExt(e.ext);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openEntry(e),
        onLongPress: () => _showMenu(e),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.dark
                ? const Color(0xFF0F0F0F)
                : const Color(0xFFFFFFFF),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.stroke, width: 1),
          ),
          child: Row(
            children: [
              DshIcon(
                icon,
                size: 20,
                color: e.isDir ? c.accent : c.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      e.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, color: c.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      e.isDir
                          ? formatFsTime(e.mtime)
                          : '${formatBytes(e.size)} · ${formatFsTime(e.mtime)}',
                      style: TextStyle(fontSize: 11, color: c.textTertiary),
                    ),
                  ],
                ),
              ),
              /*
               * 三个点**必须是真按钮**。
               *
               * 之前这里只是一个装饰性的 DshIcon —— 长得像菜单按钮，点了却什么都没发生
               * （动作只挂在整行的长按上）。用户原话：「明明文件后面有三个点，
               * 但是点击没有任何反应，反而是长按文件才会打开窗口」。
               *
               * 现在：点它 = 打开同一个操作菜单，长按整行也照旧（两条路都通）。
               * 尺寸给足 40×40，符合可点区域的最小值。
               */
              SizedBox(
                width: 40,
                height: 40,
                child: IconButton(
                  onPressed: () => _showMenu(e),
                  tooltip: '更多操作',
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  icon: DshIcon(DshGlyph.more, size: 18, color: c.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  DshGlyph _iconForExt(String ext) {
    switch (ext.toLowerCase()) {
      case '.png':
      case '.jpg':
      case '.jpeg':
      case '.gif':
      case '.webp':
        return DshGlyph.image;
      case '.mp4':
      case '.mkv':
      case '.avi':
        return DshGlyph.fileVideo;
      case '.mp3':
      case '.wav':
      case '.flac':
        return DshGlyph.fileAudio;
      case '.zip':
      case '.7z':
      case '.rar':
        return DshGlyph.fileArchive;
      case '.apk':
        return DshGlyph.fileApk;
      case '.pdf':
        return DshGlyph.filePdf;
      case '.js':
      case '.ts':
      case '.kt':
      case '.dart':
      case '.py':
      case '.json':
      case '.yml':
      case '.yaml':
        return DshGlyph.fileCode;
      default:
        return DshGlyph.fileText;
    }
  }

  void _showMenu(FsEntry e) {
    final c = DshColors.of(widget.dark);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.sheetFill,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(
                e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: c.textPrimary,
                ),
              ),
            ),
            if (!e.isDir) ...[
              ListTile(
                titleAlignment: ListTileTitleAlignment.center,
                leading: DshIcon(
                  DshGlyph.cloud,
                  size: 20,
                  color: c.textPrimary,
                ),
                title: Text('下载到本地', style: TextStyle(color: c.textPrimary)),
                subtitle: Text(
                  '交给系统下载器（浏览器里看进度，最快）',
                  style: TextStyle(fontSize: 11.5, color: c.textTertiary),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _saveToLocal(e);
                },
              ),
              ListTile(
                titleAlignment: ListTileTitleAlignment.center,
                leading: DshIcon(
                  DshGlyph.link,
                  size: 20,
                  color: c.textSecondary,
                ),
                title: Text('复制下载链接', style: TextStyle(color: c.textSecondary)),
                subtitle: Text(
                  '票据 60 秒一次性有效',
                  style: TextStyle(fontSize: 11.5, color: c.textTertiary),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _download(e);
                },
              ),
            ],
            ListTile(
              titleAlignment: ListTileTitleAlignment.center,
              leading: DshIcon(DshGlyph.edit, size: 20, color: c.textPrimary),
              title: Text('重命名', style: TextStyle(color: c.textPrimary)),
              onTap: () {
                Navigator.pop(ctx);
                _rename(e);
              },
            ),
            ListTile(
              titleAlignment: ListTileTitleAlignment.center,
              leading: DshIcon(DshGlyph.delete, size: 20, color: c.danger),
              title: Text('删除', style: TextStyle(color: c.danger)),
              onTap: () {
                Navigator.pop(ctx);
                _delete(e);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/* ---------------- 文本预览 ---------------- */

class _PreviewDialog extends StatefulWidget {
  final String title;
  final String text;
  final bool dark;
  final Future<void> Function(String) onSave;

  const _PreviewDialog({
    required this.title,
    required this.text,
    required this.dark,
    required this.onSave,
  });

  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  late final TextEditingController _ctrl;
  bool _edited = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.text);
    _ctrl.addListener(() {
      if (!_edited) setState(() => _edited = true);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = DshColors.of(widget.dark);
    return Dialog(
      backgroundColor: c.sheetFill,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 120),
                  decoration: BoxDecoration(
                    color: c.inputFill,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: c.stroke),
                  ),
                  padding: const EdgeInsets.all(10),
                  child: SingleChildScrollView(
                    child: TextField(
                      controller: _ctrl,
                      maxLines: null,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: c.textPrimary,
                        fontFamily: 'monospace',
                      ),
                      decoration: const InputDecoration.collapsed(hintText: ''),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _edited
                        ? () async {
                            await widget.onSave(_ctrl.text);
                            if (context.mounted) Navigator.pop(context);
                          }
                        : null,
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
