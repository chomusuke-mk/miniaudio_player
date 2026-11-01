/// Event emitted when the playback queue approaches its end and Infinite Mix is active.
class NeedMoreTracksEvent {
  /// The unique ID of the track currently playing or being prepared.
  final int currentTrackId;

  /// Number of tracks remaining ahead in the queue.
  final int remainingTracks;

  /// Creates a [NeedMoreTracksEvent] notification.
  const NeedMoreTracksEvent({
    required this.currentTrackId,
    required this.remainingTracks,
  });

  @override
  String toString() =>
      'NeedMoreTracksEvent(currentTrackId: $currentTrackId, remainingTracks: $remainingTracks)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NeedMoreTracksEvent &&
          runtimeType == other.runtimeType &&
          currentTrackId == other.currentTrackId &&
          remainingTracks == other.remainingTracks;

  @override
  int get hashCode => Object.hash(currentTrackId, remainingTracks);
}
