import 'dart:async';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffprobe_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class FfmpegService {
  bool get isWindows => Platform.isWindows;
  Process? _activeProcess;

  Future<String> get _windowsFfmpegPath async {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final ffmpegExe = p.join(exeDir, 'data', 'flutter_assets', 'windows_assets', 'ffmpeg.exe');
    return ffmpegExe;
  }

  Future<int> getVideoDurationSec(String videoPath) async {
    if (isWindows) {
      final ffmpeg = await _windowsFfmpegPath;
      if (!await File(ffmpeg).exists()) return 1;
      
      final result = await Process.run(ffmpeg, ['-i', videoPath]);
      // ffprobe is better, but we only have ffmpeg.exe bundled for now.
      // FFmpeg prints info to stderr.
      final output = result.stderr.toString();
      final regex = RegExp(r"Duration: (\d{2}):(\d{2}):(\d{2})\.(\d{2})");
      final match = regex.firstMatch(output);
      if (match != null) {
        int h = int.parse(match.group(1)!);
        int m = int.parse(match.group(2)!);
        int s = int.parse(match.group(3)!);
        return h * 3600 + m * 60 + s;
      }
      return 1;
    } else {
      final session = await FFprobeKit.getMediaInformation(videoPath);
      final mediaInfo = session.getMediaInformation();
      if (mediaInfo != null) {
        return double.parse(mediaInfo.getDuration() ?? "1").toInt();
      }
      return 1;
    }
  }

  Future<bool> checkHardwareAcceleration(String encoder) async {
    // 1-frame micro-test
    final args = [
      '-f', 'lavfi',
      '-i', 'color=c=black:s=64x64:d=0.1',
      '-c:v', encoder,
      '-f', 'null',
      '-'
    ];

    if (isWindows) {
      final ffmpeg = await _windowsFfmpegPath;
      if (!await File(ffmpeg).exists()) return false;
      final result = await Process.run(ffmpeg, args);
      return result.exitCode == 0;
    } else {
      final session = await FFmpegKit.executeWithArguments(args);
      final returnCode = await session.getReturnCode();
      return returnCode?.isValueSuccess() ?? false;
    }
  }

  /// Returns the path to the modified ASS file
  Future<String> modifyAssFont(String assPath, String fontName) async {
    final file = File(assPath);
    String content = await file.readAsString();
    
    // Simplistic modification: replace Fontname in styles with the English font name.
    // Standard ASS Style format: Style: Name,Fontname,Fontsize,...
    final lines = content.split('\n');
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('Style:')) {
        final parts = lines[i].split(',');
        if (parts.length > 1) {
          parts[1] = fontName;
          lines[i] = parts.join(',');
        }
      }
    }

    final tempDir = await getTemporaryDirectory();
    final tempAss = File(p.join(tempDir.path, 'temp_modified.ass'));
    await tempAss.writeAsString(lines.join('\n'));
    return tempAss.path;
  }

  String _escapeFilterPath(String path) {
    // FFmpeg requires double escaping for filter_complex when not using single quotes:
    // Level 1: filter parser, Level 2: option parser.
    return path.replaceAll(r'\', r'\\\\')
               .replaceAll(':', r'\\:')
               .replaceAll('[', r'\\[')
               .replaceAll(']', r'\\]')
               .replaceAll(' ', r'\\ ')
               .replaceAll(',', r'\\,')
               .replaceAll(';', r'\\;')
               .replaceAll('=', r'\\=')
               .replaceAll("'", r"\\'");
  }

  Future<void> exportVideo({
    required String videoPath,
    required String assPath,
    required String fontName,
    required String fontSandboxDir,
    required String outputPath,
    required bool useHwAccel,
    required bool padVideo,
    required Function(double) onProgress,
  }) async {
    final totalDuration = await getVideoDurationSec(videoPath);
    final modifiedAss = await modifyAssFont(assPath, fontName);
    
    String encoder = 'libx264';
    if (useHwAccel) {
      List<String> testEncoders = isWindows ? ['h264_nvenc', 'h264_qsv', 'h264_amf'] : ['h264_mediacodec', 'h264_videotoolbox'];
      for (String enc in testEncoders) {
        if (await checkHardwareAcceleration(enc)) {
          encoder = enc;
          break;
        }
      }
    }

    String finalAssPath = _escapeFilterPath(modifiedAss);
    String finalFontsDir = _escapeFilterPath(fontSandboxDir);
    String filterGraph = '';
    
    if (padVideo) {
      // Dynamic padding to 16:9, preserving original resolution and ensuring even dimensions
      filterGraph = '[0:v]pad=width=\'ceil(max(iw\\,ih*16/9)/2)*2\':height=\'ceil(max(ih\\,iw*9/16)/2)*2\':x=-1:y=-1[padded];[padded]ass=f=$finalAssPath:fontsdir=$finalFontsDir,format=yuv420p[out]';
    } else {
      filterGraph = '[0:v]ass=f=$finalAssPath:fontsdir=$finalFontsDir,format=yuv420p[out]';
    }

    final args = [
      '-y',
      '-i', videoPath,
      '-filter_complex', filterGraph,
      '-map', '[out]',
      '-map', '0:a?',
      '-c:v', encoder,
      '-c:a', 'copy',
      outputPath
    ];

    if (isWindows) {
      final ffmpeg = await _windowsFfmpegPath;
      if (!await File(ffmpeg).exists()) {
        throw Exception("FFmpeg binary not found at $ffmpeg. Please bundle it.");
      }

      _activeProcess = await Process.start(ffmpeg, args, environment: {
        'FONTCONFIG_PATH': fontSandboxDir,
        'GDFONTPATH': fontSandboxDir,
        'FFREPORT': 'level=32', // prevent quiet stderr starvation
      });

      final stderrBuffer = StringBuffer();
      _activeProcess!.stderr.transform(SystemEncoding().decoder).listen((output) {
        print('FFMPEG LOG: $output');
        stderrBuffer.write(output);
        final regex = RegExp(r"time=(\d{2}):(\d{2}):(\d{2})\.(\d{2})");
        final match = regex.firstMatch(output);
        if (match != null) {
          int h = int.parse(match.group(1)!);
          int m = int.parse(match.group(2)!);
          int s = int.parse(match.group(3)!);
          int currentSec = h * 3600 + m * 60 + s;
          double progress = (currentSec / totalDuration);
          onProgress(progress.clamp(0.0, 1.0));
        }
      });

      final exitCode = await _activeProcess!.exitCode;
      _activeProcess = null;
      if (exitCode != 0) {
        throw Exception("FFmpeg encoding failed on Windows (exit code $exitCode).\nLog:\n$stderrBuffer");
      }
    } else {
      // Mobile - execute with environment variables for libass
      FFmpegKitConfig.setEnvironmentVariable('FONTCONFIG_PATH', fontSandboxDir);
      FFmpegKitConfig.setEnvironmentVariable('GDFONTPATH', fontSandboxDir);
      
      // We use FFmpegKit's async execution
      final completer = Completer<void>();
      await FFmpegKit.executeWithArgumentsAsync(
        args, 
        (session) async {
          final returnCode = await session.getReturnCode();
          if (returnCode?.isValueSuccess() == true) {
            completer.complete();
          } else {
            final failLog = await session.getOutput();
            completer.completeError(Exception("FFmpeg encoding failed (code $returnCode).\nLog:\n$failLog"));
          }
        }, 
        (log) {}, 
        (statistics) {
          double currentSec = statistics.getTime() / 1000.0;
          double progress = (currentSec / totalDuration);
          onProgress(progress.clamp(0.0, 1.0));
        }
      );
      await completer.future;
    }
  }

  void cancelExport() {
    if (isWindows && _activeProcess != null) {
      _activeProcess!.kill();
    } else if (!isWindows) {
      FFmpegKit.cancel();
    }
  }
}
