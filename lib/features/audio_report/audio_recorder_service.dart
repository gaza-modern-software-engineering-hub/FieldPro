import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class AudioRecorderService {
  final AudioRecorder _rec = AudioRecorder();

  /// تسجيل كلام: AAC-ADTS أحادي 16kHz بمعدل 32kbps (≈14 ميغابايت للساعة).
  /// صيغة ADTS لا تتلف إذا انقطع التسجيل فجأة.
  Future<String> start() async {
    if (!await _rec.hasPermission()) {
      throw Exception('لم يتم إعطاء إذن استخدام الميكروفون');
    }
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/FieldPro_audio');
    if (!await dir.exists()) await dir.create(recursive: true);
    final path =
        '${dir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 24000,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    return path;
  }

  Future<void> pause() => _rec.pause();
  Future<void> resume() => _rec.resume();
  Future<String?> stop() => _rec.stop();
  Future<bool> isRecording() => _rec.isRecording();
  Future<void> dispose() => _rec.dispose();
}