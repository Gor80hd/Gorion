/// Profile connection mode for home page compatibility.
enum ProfileConnectionMode {
  /// Only one profile active at a time (Gorion default).
  currentProfile,

  /// All profiles' servers merged into a single pool.
  mergedProfiles,
}
