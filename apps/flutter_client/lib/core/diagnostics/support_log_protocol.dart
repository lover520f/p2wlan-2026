/// Limits shared by the support-log collector and its wire encoder.
///
/// A default desktop client can run eight friend rooms at once.  Each room
/// contributes at most its daemon log and one generated status summary, in
/// addition to the main daemon and Flutter client logs.  Keeping these values
/// explicit prevents the collector from producing a normal payload that the
/// server rejects solely because the two sides disagreed on file counts.
const maxSupportLogRoomInstances = 8;
const maxSupportLogInstancesV2 = 1 + maxSupportLogRoomInstances;
const maxSupportLogFilesV2 = 2 + (maxSupportLogRoomInstances * 2);
const maxTrackedSupportLogRoomInstances = maxSupportLogRoomInstances * 2;

const maxSupportLogExpandedBytes = 32 * 1024 * 1024;
const maxSupportLogCompressedBytes = 8 * 1024 * 1024;

class SupportLogRoomSelection {
  const SupportLogRoomSelection({
    required this.retainedProfileIds,
    required this.omittedProfileIds,
  });

  final List<String> retainedProfileIds;
  final List<String> omittedProfileIds;
}

/// Keeps the supplied priority order, deduplicates valid local profile ids,
/// and makes any overflow explicit for the v2 manifest.  The collector uses
/// the retained ids while the omitted count explains why an older room is not
/// in this particular support bundle.
SupportLogRoomSelection selectSupportLogRoomProfiles(
  Iterable<String> profileIds,
) {
  final retained = <String>[];
  final omitted = <String>[];
  final seen = <String>{};
  final profileIdPattern = RegExp(r'^[a-f0-9]{64}$');
  for (final rawProfileId in profileIds) {
    final profileId = rawProfileId.trim();
    if (!profileIdPattern.hasMatch(profileId) || !seen.add(profileId)) {
      continue;
    }
    if (retained.length < maxSupportLogRoomInstances) {
      retained.add(profileId);
    } else {
      omitted.add(profileId);
    }
  }
  return SupportLogRoomSelection(
    retainedProfileIds: List.unmodifiable(retained),
    omittedProfileIds: List.unmodifiable(omitted),
  );
}
