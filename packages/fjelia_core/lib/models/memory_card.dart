/// A memory card: what the athlete wants the AI Coach to know, in their own
/// words. The app's database rows implement this view.
abstract interface class MemoryCardView {
  String get id;
  String get title;
  String get body;
  DateTime get createdAt;
  DateTime get updatedAt;
}
