import Foundation

/// Column counts for tile grids whose item count varies.
public enum GridLayout {
    /// Columns for `count` tiles so that rows come out as full and as even as
    /// possible. Everything fits on one row up to `maxColumns`; beyond that
    /// the row count is the fewest that will do, and the columns are what
    /// that many rows need — so 6 tiles become 3 + 3 rather than 4 + 2, and
    /// 11 become 4 + 4 + 3 rather than 5 + 5 + 1. A fixed column count put
    /// one lonely tile on the second row as soon as there were five. No row
    /// is ever a single tile for any count this app can produce (the
    /// overview plus up to eleven providers); the rule is not a general
    /// guarantee — 21 tiles leave one over at every column count.
    public static func balancedColumns(count: Int, maxColumns: Int = 5) -> Int {
        guard count > 0, maxColumns > 0 else { return 1 }
        let rows = (count + maxColumns - 1) / maxColumns
        return (count + rows - 1) / rows
    }
}
