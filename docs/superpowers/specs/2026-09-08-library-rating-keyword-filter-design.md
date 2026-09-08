# Library Rating, Keyword, and Filter Design

## Scope

This design covers the first implementation unit of the editor workflow UX
Phase 3: persistent photo rating and flag state, keyword ownership, the shared
query model, and the Mac presentation wiring for advanced catalog filters. It
does not change the RAW sidecar schema or rendering pipeline.

## Photo identity state

- `rating` is an integer from 0 through 5. `0` means unrated; values 1...5
  are the visible star rating.
- `flag` is one of `none`, `pick`, or `reject`.
- Rating and flag belong to the `PhotoID`, not to the source file path. A scan
  updates file facts but never resets either value.
- A virtual copy starts with rating 0 and flag `none`; it does not inherit
  either state from its source. Each copy is an independent curation identity.

## Keywords

- Keywords are stored in a separate `photo_keyword` table keyed by
  `(photo_id, normalized_keyword)`.
- Input is trimmed, NFC-normalized, and lowercased for matching. The first
  display spelling is retained in `display_value` until that keyword is
  removed.
- Empty or whitespace-only values are rejected. Duplicate values after
  normalization collapse to one row.
- Keywords belong to the `PhotoID`; virtual copies start empty and have their
  own keyword set. This avoids silently assigning an editorial label to a new
  version that the user has not reviewed.
- Deleting a photo cascades to its keyword rows. Rebuilding the index starts
  with an empty keyword set because the SQLite index is rebuildable cache data;
  a future sidecar/export design may persist keywords separately.

## Query contract

`LibraryQuery` keeps all filters in one value so filename search and filters
share one query fingerprint. The first implementation exposes:

- exact rating (`unrated` or `1...5`),
- exact flag,
- `hasEdits`,
- normalized file format, camera, and lens values,
- inclusive capture-date range,
- exact normalized keyword.

All optional filters compose with scope and filename search using SQL `AND`.
Cursor paging remains keyed only by the selected sort; callers must retain the
full query value when reusing a cursor.

The Mac browser exposes the lightweight rating/flag/edit-state choices in the
toolbar menu. Format, camera, lens, capture-date range, and exact keyword are
staged in an Advanced Filters sheet and applied as one query update. A selected
photo can edit its complete keyword set from the toolbar or cell context menu;
comma/newline input is split before it reaches the index mutation API.

## Migration and rollback

Schema version 4 adds `photo.rating`, `photo.flag`, and
`photo.format_normalized`, plus the `photo_keyword` table and indexes. The
columns and table are created inside the existing single migration transaction;
any migration-hook failure rolls the complete change back. Existing rows get
rating 0, flag `none`, and a backfilled normalized extension.
