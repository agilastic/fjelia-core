import '../../models/hrv_pair_assessment.dart';
import '../../models/hrv_training_episode.dart';
import 'hrv_pairing_service.dart';

/// Everything the card, the chart, the reminder and the AI read, built from
/// the same facts in one pass.
class HrvSnapshot {
  const HrvSnapshot({
    required this.episodes,
    required this.measurements,
    required this.pairings,
    required this.assessments,
    required this.intervening,
    required this.asOf,
  });
  final List<EpisodeFact> episodes;
  final List<MeasurementFact> measurements;
  final Map<String, EpisodePairing> pairings;
  final Map<String, HrvPairAssessment> assessments;

  /// Episodes followed by another workout before a post was taken.
  final Set<String> intervening;
  final DateTime asOf;

  EpisodeFact? episode(String id) {
    for (final e in episodes) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// The episode a measurement is the pre or post of, or null.
  String? episodeOfMeasurement(String uid) {
    for (final p in pairings.values) {
      if (p.pre?.uid == uid ||
          p.post?.uid == uid ||
          p.additionalPosts.any((m) => m.uid == uid)) {
        return p.episodeId;
      }
    }
    return null;
  }
}
