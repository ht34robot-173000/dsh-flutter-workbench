/// DSH 工作台 —— 扫码配对页（阶段⑤）。
///
/// 两条入口：
///   1. 实时扫码（相机预览 + 连续识别）
///   2. 从图库选一张二维码图片解码
///
/// ⚠️ 二维码内容格式（照桌面端 `client.js:918`）：
///
///     <baseUrl>/rw/pair?code=123456
///
/// 所以解析要**同时**拿到 baseUrl 和 code —— 只拿到 code 没法知道连哪台机器。
/// 这是「扫了码但连不上」的常见原因：早期只取了 code，baseUrl 还是旧的。
///
/// 配对接口：`POST /rw/pair/accept` body `{token}`，
/// 宿主 `auth.accept()` 同时接受 6 位 code 和 nonce 串。
library;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/scan_parse.dart';
import 'icons.dart';
import 'theme.dart';

/// 扫码页。成功时 `Navigator.pop` 回一个 [PairScanResult]。
class ScanPage extends StatefulWidget {
  final bool dark;

  const ScanPage({super.key, required this.dark});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  MobileScannerController? _ctrl;
  bool _handled = false;
  String? _lastError;

  /// 相机是否可用。不可用时界面只留「从图库选」一个入口。
  bool _cameraReady = false;
  bool _cameraFailed = false;

  @override
  void initState() {
    super.initState();
    _startCamera();
  }

  void _startCamera() {
    try {
      final c = MobileScannerController(
        // 只认二维码：条形码要横着扫，在这个竖屏里识别率极低还会拖慢
        formats: const [BarcodeFormat.qrCode],
        detectionSpeed: DetectionSpeed.noDuplicates,
        // 关掉自动闪光，避免进页面就闪一下吓人
        torchEnabled: false,
      );
      _ctrl = c;
      _cameraReady = true;
    } catch (e) {
      _cameraFailed = true;
      _lastError = '相机启动失败：$e';
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null || raw.isEmpty) continue;
      _acceptRaw(raw);
      return;
    }
  }

  /// 统一处理一条扫描结果（相机和图库都走这里）。
  void _acceptRaw(String raw) {
    final parsed = parsePairQr(raw);
    if (parsed == null) {
      // 不是本应用的码 —— 别静默忽略，要让用户知道扫到了但用不了
      setState(() => _lastError = '这不是 DSH 的配对码');
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
          content: Text('这不是 DSH 的配对码'),
          duration: Duration(seconds: 2),
        ));
      return;
    }
    if (_handled) return;
    _handled = true;
    Navigator.of(context).pop(parsed);
  }

  /// 从图库选一张二维码图片解码。
  ///
  /// ⚠️ **`allowCompression: false` 是必须的，不是优化。**
  ///
  /// file_picker 8.3.7 的 Android 端默认 `allowCompression=true` +
  /// `compressionQuality=30`，只要 `type` 是 `image/*` 就会走
  /// `FileUtils.compressImage(uri, ...)`。它对该 content URI 直接
  /// `openInputStream`，在 Android 13+ 上抛：
  ///
  /// ```
  /// RuntimeException: java.io.FileNotFoundException:
  ///   Failed to validate: content://media/external/images/media/38
  ///   at FileUtils.compressImage(FileUtils.java:108)
  /// ```
  ///
  /// **这个异常在后台 `Thread-4` 里抛，Dart 侧的 try/catch 根本接不住，
  /// 进程直接被 `SIG:9` 杀掉。** 实测：选一张图 → App 闪退回桌面，
  /// 日志里是 `FATAL EXCEPTION Thread-4`。
  ///
  /// 关掉压缩后走原始路径，不碰 ContentResolver 的验证逻辑。
  Future<void> _pickFromGallery() async {
    try {
      // mobile_scanner 6.x 没有 analyzeImageFromGallery()，
      // 只能自己用 file_picker 拿路径，再喂给 analyzeImage(path)。
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: false,
        allowCompression: false,
      );
      if (picked == null || picked.files.isEmpty) return;
      final path = picked.files.first.path;
      if (path == null) {
        if (!mounted) return;
        setState(() => _lastError = '拿不到图片路径');
        return;
      }

      final result = await _ctrl?.analyzeImage(path);
      if (result == null) {
        if (!mounted) return;
        setState(() => _lastError = '这张图里没找到二维码');
        return;
      }
      for (final b in result.barcodes) {
        final raw = b.rawValue;
        if (raw != null && raw.isNotEmpty) {
          _acceptRaw(raw);
          return;
        }
      }
      if (!mounted) return;
      setState(() => _lastError = '这张图里没找到二维码');
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('这张图里没找到二维码')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastError = '读图失败：$e');
    }
  }

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
                _bar(c),
                Expanded(child: _preview(c)),
                _bottom(c),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bar(DshColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
      child: Row(
        children: [
          IconButton(
            icon: DshIcon(DshGlyph.back, size: 20, color: c.textPrimary),
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            padding: const EdgeInsets.all(8),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 2),
          Text(
            '扫码配对',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: c.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _preview(DshColors c) {
    if (_cameraFailed || _ctrl == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DshIcon(DshGlyph.info, size: 34, color: c.danger),
              const SizedBox(height: 12),
              Text(
                '相机不可用',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '可以用下面的「从图库选图」',
                style: TextStyle(fontSize: 12.5, color: c.textSecondary),
              ),
              if (_lastError != null) ...[
                const SizedBox(height: 10),
                Text(
                  _lastError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: c.textTertiary),
                ),
              ],
            ],
          ),
        ),
      );
    }

    // 相机预览用圆角方形开窗，配一个取景框。
    // 用固定尺寸而不是 MATCH_PARENT：踩坑文档 6.4 记过，
    // 全屏预览会把底部提示挤到一起，和手势区重叠。
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.accent, width: 2),
            ),
            clipBehavior: Clip.antiAlias,
            child: _cameraReady
                ? MobileScanner(
                    controller: _ctrl!,
                    onDetect: _onDetect,
                    // 相机被拒时给一句人话，不要空白。
                    // 签名是 (context, exception, child) 三个参数 ——
                    // 少了第三个参数会类型不匹配。
                    errorBuilder: (context, error, child) {
                      return Container(
                        color: c.inputFill,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          '相机打不开：${error.errorCode.name}\n可以改用「从图库选图」',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                        ),
                      );
                    },
                  )
                : Container(color: c.inputFill),
          ),
          const SizedBox(height: 14),
          Text(
            _lastError ?? '把配对二维码对准取景框',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              color: _lastError != null ? c.danger : c.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottom(DshColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _pickFromGallery,
          icon: DshIcon(DshGlyph.image, size: 18, color: c.accent),
          label: Text(
            '从图库选图',
            style: TextStyle(fontSize: 13.5, color: c.accent),
          ),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 13),
            side: BorderSide(color: c.accent, width: 1),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      ),
    );
  }
}



