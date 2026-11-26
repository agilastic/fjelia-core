import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fjelia_core/models/ecg.dart';
import 'package:fjelia_core/services/ecg_analysis.dart';

export 'package:fjelia_core/services/ecg_analysis.dart' show analyzeEcg;
import 'package:fjelia_data/database.dart';
import 'package:fjelia_data/sync.dart';

import 'health.dart' show EcgItem;

/// Where an ECG recording's waveform is.
enum EcgWaveformState {
  /// On this device: shown and analysed.
  here,

  /// Only on the phone that recorded it; it can be asked for.
  onPhone,

  /// Asked for; it comes with that phone's next sync.
  requested,

  /// A report without a waveform (an imported PDF, say).
  none,
}

/// One ECG recording with its waveform, when this device has it, and the
/// training reading of it: heart rate, heart-rate variability and signal
/// quality. Never a medical reading.
class EcgDetail {
  const EcgDetail({
    required this.item,
    required this.state,
    this.sampleRateHz,
    this.chunks = const [],
    this.analysis,
    this.complete = false,
  });
  final EcgItem item;
  final EcgWaveformState state;
  final double? sampleRateHz;
  final List<EcgChunk> chunks;
  final EcgAnalysis? analysis;

  /// Every sample of the recording is here; a sync may still be bringing
  /// the rest while this is false.
  final bool complete;

  EcgDetail withAnalysis(EcgAnalysis a) => EcgDetail(
    item: item,
    state: state,
    sampleRateHz: sampleRateHz,
    chunks: chunks,
    analysis: a,
    complete: complete,
  );

  /// Seconds of waveform this device has.
  double get seconds {
    final hz = sampleRateHz;
    if (chunks.isEmpty || hz == null) return 0;
    return chunks.last.offsetUs / 1e6 + chunks.last.microvolts.length / hz;
  }
}

/// The ECG waveform chunks of [recordingId], in order, without the
/// accelerometer stream recorded alongside.
Future<List<EcgChunk>> loadEcgChunks(
  AppDatabase db,
  String recordingId,
) async => [
  for (final c
      in await (db.select(db.ecgSampleChunks)
            ..where((t) => t.recordingId.equals(recordingId))
            ..orderBy([(t) => OrderingTerm(expression: t.sequence)]))
          .get())
    if (jsonDecode(c.dataJson) case final Map<String, dynamic> json
        when json['stream'] != 'acc')
      EcgChunk.fromJson(json),
];

/// [recordingId] with its waveform and reading, or null when it is gone.
/// With [analyse] false the reading is left out, for a caller that runs
/// [analyzeEcg] elsewhere: a night's recording takes a while.
Future<EcgDetail?> loadEcgDetail(
  AppDatabase db,
  String recordingId, {
  bool analyse = true,
}) async {
  final row = await (db.select(
    db.ecgRecordings,
  )..where((t) => t.recordingId.equals(recordingId))).getSingleOrNull();
  if (row == null) return null;
  final item = EcgItem(
    id: row.recordingId,
    recordedAt: row.recordedAt,
    kind: row.kind,
    duration: Duration(milliseconds: row.durationMs),
    device: row.deviceName,
    note: row.note,
  );
  final hz = row.sampleRateHz;
  if (hz == null || hz <= 0 || row.sampleCount == 0) {
    return EcgDetail(item: item, state: EcgWaveformState.none);
  }
  final chunks = await loadEcgChunks(db, recordingId);
  if (chunks.isEmpty) {
    return EcgDetail(
      item: item,
      sampleRateHz: hz,
      state: await db.ecgWaveformWanted(recordingId)
          ? EcgWaveformState.requested
          : EcgWaveformState.onPhone,
    );
  }
  return EcgDetail(
    item: item,
    state: EcgWaveformState.here,
    sampleRateHz: hz,
    chunks: chunks,
    complete:
        chunks.fold(0, (n, c) => n + c.microvolts.length) >= row.sampleCount,
    // No clinical rules: heart rate, HRV and quality for training only.
    analysis: analyse ? analyzeEcg(chunks, hz) : null,
  );
}
