#if os(iOS)
/// Re-exports the core so a publisher writes one import.
///
/// Without this, integration code that touches `SlotResolution`, `PassthroughCause` or
/// `LongitudeSlotPlan` — all of which appear in the public banner API — needs a second
/// `import LongitudeCore`, and the migration story stops being "one import". The split
/// between the two modules is an internal concern of ours: it exists so the logic can be
/// tested on the macOS host, not because publishers should care.
///
/// `@_exported` is underscored but is the only mechanism Swift offers for this, and is
/// what Apple's own umbrella modules use.
@_exported import LongitudeCore
#endif
