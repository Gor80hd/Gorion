/// Profile connection mode for home page compatibility.
enum ProfileConnectionMode {
  /// Only one profile active at a time (gorion_clean default).
  currentProfile,

  /// All profiles' servers merged into a single pool.
  mergedProfiles,
}
