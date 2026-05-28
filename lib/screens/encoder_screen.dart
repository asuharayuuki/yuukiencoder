import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import '../services/ffmpeg_service.dart';
import '../services/font_service.dart';

class EncoderScreen extends StatefulWidget {
  const EncoderScreen({super.key});

  @override
  State<EncoderScreen> createState() => _EncoderScreenState();
}

class _EncoderScreenState extends State<EncoderScreen> {
  late final Player player;
  late final VideoController controller;
  
  final FfmpegService _ffmpegService = FfmpegService();
  final FontService _fontService = FontService();

  String? _videoPath;
  String? _assPath;
  String? _fontInternalName;
  
  bool _useHwAccel = true;
  bool _padVideo = true;
  bool _isExporting = false;
  double _exportProgress = 0.0;

  @override
  void initState() {
    super.initState();
    player = Player(configuration: const PlayerConfiguration(libass: true));
    controller = VideoController(player);
    _cleanupTempFiles();
  }

  Future<void> _cleanupTempFiles() async {
    if (Platform.isIOS || Platform.isAndroid) {
      try {
        final tempDir = await getTemporaryDirectory();
        final files = tempDir.listSync();
        for (final file in files) {
          if (file is File && p.basename(file.path).startsWith('encoded_output_')) {
            file.deleteSync();
          }
        }
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }



  Future<void> _pickVideo() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mkv', 'avi', 'mov', 'flv', 'webm', 'wmv', 'ts', 'm4v'],
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        _videoPath = result.files.single.path!;
      });
      _reloadPreview();
    }
  }

  Future<void> _pickAss() async {
    final result = await FilePicker.pickFiles(
        type: FileType.custom, allowedExtensions: ['ass']);
    if (result != null && result.files.single.path != null) {
      setState(() {
        _assPath = result.files.single.path!;
      });
      _reloadPreview();
    }
  }

  Future<void> _pickFont() async {
    final result = await FilePicker.pickFiles(
        type: FileType.custom, allowedExtensions: ['ttf', 'otf']);
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      try {
        final fontName = await _fontService.processAndSandboxFont(path);
        setState(() => _fontInternalName = fontName);
        _reloadPreview();
      } catch (e) {
        if(mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error loading font: $e')));
        }
      }
    }
  }

  Future<void> _reloadPreview() async {
    if (_videoPath != null) {
      // First, set the subtitle fonts directory if we have one
      if (_fontInternalName != null) {
        final sandboxDir = await _fontService.getSandboxFontsDir();
        try {
          (player.platform as dynamic).setProperty('sub-fonts-dir', sandboxDir);
        } catch (e) {
          debugPrint('Failed to set sub-fonts-dir: $e');
        }
      }
      
      await player.open(Media(_videoPath!));
      if (_assPath != null) {
        String subtitlePathToLoad = _assPath!;
        if (_fontInternalName != null) {
          subtitlePathToLoad = await _ffmpegService.modifyAssFont(_assPath!, _fontInternalName!);
        }
        await player.setSubtitleTrack(SubtitleTrack.uri(subtitlePathToLoad));
      }
    }
  }

  Future<void> _exportVideo() async {
    if (_videoPath == null || _assPath == null || _fontInternalName == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select Video, Subtitle, and Font.')));
      return;
    }

    String defaultOutputName = 'encoded_output';
    if (_videoPath != null) {
      defaultOutputName = '${p.basenameWithoutExtension(_videoPath!)}_output';
    }
    final fileName = '$defaultOutputName.mp4';

    String? outputPath;
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      outputPath = await FilePicker.saveFile(
        dialogTitle: 'Save Encoded Video',
        type: FileType.video,
        allowedExtensions: ['mp4'],
        fileName: fileName
      );
      if (outputPath == null) return;
    } else {
      // On mobile, saveFile returns null. We save to temp dir first, then share it.
      final tempDir = await getTemporaryDirectory();
      outputPath = p.join(tempDir.path, fileName);
    }

    setState(() {
      _isExporting = true;
      _exportProgress = 0.0;
    });

    try {
      final sandboxDir = await _fontService.getSandboxFontsDir();
      await _ffmpegService.exportVideo(
        videoPath: _videoPath!,
        assPath: _assPath!,
        fontName: _fontInternalName!,
        fontSandboxDir: sandboxDir,
        outputPath: outputPath,
        useHwAccel: _useHwAccel,
        padVideo: _padVideo,
        onProgress: (progress) {
          setState(() {
            _exportProgress = progress;
          });
        }
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Export Complete!')));
      }
      if (Platform.isIOS || Platform.isAndroid) {
        final xFile = XFile(outputPath);
        await Share.shareXFiles([xFile]);
        try {
          final file = File(outputPath);
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {}
      }
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Export Error'),
            content: SingleChildScrollView(
              child: SelectableText(e.toString()),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: e.toString()));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
                },
                child: const Text('Copy Error'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } finally {
      setState(() {
        _isExporting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('yuukiencoder')),
      body: Column(
        children: [
          Expanded(
            flex: 2,
            child: Video(
              controller: controller,
              subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
            ),
          ),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: ListView(
                children: [
                  ListTile(
                    leading: const Icon(Icons.video_file),
                    title: Text(_videoPath != null ? _videoPath!.split(Platform.pathSeparator).last : 'No Video Selected'),
                    trailing: ElevatedButton(onPressed: _isExporting ? null : _pickVideo, child: const Text('Select Video')),
                  ),
                  ListTile(
                    leading: const Icon(Icons.subtitles),
                    title: Text(_assPath != null ? _assPath!.split(Platform.pathSeparator).last : 'No Subtitle Selected'),
                    trailing: ElevatedButton(onPressed: _isExporting ? null : _pickAss, child: const Text('Select ASS')),
                  ),
                  ListTile(
                    leading: const Icon(Icons.font_download),
                    title: Text(_fontInternalName ?? 'No Font Selected'),
                    trailing: ElevatedButton(onPressed: _isExporting ? null : _pickFont, child: const Text('Select TTF')),
                  ),
                  SwitchListTile(
                    title: const Text('Hardware Acceleration'),
                    subtitle: const Text('Auto-fallback to software if unsupported'),
                    value: _useHwAccel,
                    onChanged: _isExporting ? null : (val) => setState(() => _useHwAccel = val),
                  ),
                  SwitchListTile(
                    title: const Text('Pad Video to 16:9'),
                    subtitle: const Text('Adds black bars to maintain aspect ratio'),
                    value: _padVideo,
                    onChanged: _isExporting ? null : (val) => setState(() => _padVideo = val),
                  ),
                  const SizedBox(height: 16),
                  if (_isExporting) ...[
                    LinearProgressIndicator(value: _exportProgress),
                    const SizedBox(height: 8),
                    Text('${(_exportProgress * 100).toStringAsFixed(1)}%'),
                  ],
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _isExporting ? null : _exportVideo,
                    style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
                    child: const Text('Export Video'),
                  ),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }
}
