// A package that imports units (scripts/mutation/fixture/units): its tests
// judge the mutants of units that units' own tests leave.

///|
/// Whether `reading` lies on a scale from `low` to `high`.
pub fn on_scale(reading : Int32, low : Int32, high : Int32) -> Bool {
  @units.within(reading, low, high)
}
