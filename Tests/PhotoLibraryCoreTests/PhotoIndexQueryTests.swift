import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Spec §8.2: stable, cross-source paging plus the four scopes and four
/// sorts a query can combine. The load-bearing assertion throughout is
/// identity completeness after walking every page — no duplicate `PhotoID`,
/// no gap — not just a final count.
final class PhotoIndexQueryTests: TemporaryDirectoryTestCase {
    private var databaseURL: URL!
    private var store: PhotoIndexStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databaseURL = temporaryDirectory.appendingPathComponent("library.sqlite")
        store = try PhotoIndexStore(databaseURL: databaseURL)
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try super.tearDownWithError()
    }

    // MARK: - Cross-source keyset paging

    func testKeysetPagingAcrossSourcesHasNoDuplicatesOrGaps() throws {
        let expected = try seedThreeLibraries(photoCountPerLibrary: 137)
        let query = LibraryQuery(scope: .all, sort: .captureDateDescending)
        var cursor: PhotoPageCursor?
        var actual: [PhotoID] = []
        repeat {
            let page = try store.page(matching: query, after: cursor, limit: 100)
            actual.append(contentsOf: page.photos.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(Set(actual).count, actual.count)
    }

    func testPagingWithTiedSortValuesHasNoDuplicatesOrGaps() throws {
        // Every photo shares one capture date, forcing every page boundary
        // through the PhotoID tie-break.
        let library = try makeLibrary()
        let tiedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let photos = (0..<250).map { index -> PhotoAsset in
            var asset = PhotoAsset.stub(
                libraryID: library.id,
                relativePath: "Tied/DSC\(index).ARW",
                fingerprint: .stub("tied-\(index)")
            )
            asset.metadata.captureDate = tiedDate
            return asset
        }
        try store.upsert(photos: photos)

        let query = LibraryQuery(scope: .all, sort: .captureDateDescending)
        var cursor: PhotoPageCursor?
        var actual: [PhotoID] = []
        repeat {
            let page = try store.page(matching: query, after: cursor, limit: 40)
            actual.append(contentsOf: page.photos.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(Set(actual), Set(photos.map(\.id)))
        XCTAssertEqual(actual.count, photos.count)
    }

    func testPagingRemainsConsistentWhenARowIsDeletedBetweenPages() throws {
        let library = try makeLibrary()
        let photos = (0..<20).map { index -> PhotoAsset in
            var asset = PhotoAsset.stub(
                libraryID: library.id,
                relativePath: "D\(index).ARW",
                fingerprint: .stub("del-\(index)")
            )
            asset.metadata.captureDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            return asset
        }
        try store.upsert(photos: photos)
        // Descending by capture date: photos[19] (latest) sorts first.
        let sortedDescending = photos.sorted {
            $0.metadata.captureDate! > $1.metadata.captureDate!
        }

        let query = LibraryQuery(scope: .all, sort: .captureDateDescending)
        let firstPage = try store.page(matching: query, after: nil, limit: 5)
        XCTAssertEqual(firstPage.photos.map(\.id), Array(sortedDescending.prefix(5).map(\.id)))

        // Delete a photo that has already been returned, and one that has
        // not — neither should reappear or cause a skipped survivor.
        try store.removePhotos(ids: [sortedDescending[2].id, sortedDescending[7].id])

        var actual = firstPage.photos.map(\.id)
        var cursor = firstPage.nextCursor
        while let current = cursor {
            let page = try store.page(matching: query, after: current, limit: 5)
            actual.append(contentsOf: page.photos.map(\.id))
            cursor = page.nextCursor
        }

        let expectedSurvivors = Set(photos.map(\.id))
            .subtracting([sortedDescending[7].id])
        XCTAssertEqual(Set(actual), expectedSurvivors)
        XCTAssertEqual(actual.count, Set(actual).count)
    }

    func testPagingRemainsConsistentWhenARowIsInsertedBetweenPages() throws {
        let library = try makeLibrary()
        let photos = (0..<10).map { index -> PhotoAsset in
            var asset = PhotoAsset.stub(
                libraryID: library.id,
                relativePath: "I\(index).ARW",
                fingerprint: .stub("ins-\(index)")
            )
            asset.metadata.captureDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            return asset
        }
        try store.upsert(photos: photos)

        let query = LibraryQuery(scope: .all, sort: .captureDateDescending)
        let firstPage = try store.page(matching: query, after: nil, limit: 4)
        XCTAssertNotNil(firstPage.nextCursor)

        // Insert a photo sorting after everything already fetched (an old
        // capture date) — it must not duplicate or displace later rows.
        var lateInsert = PhotoAsset.stub(
            libraryID: library.id, relativePath: "Inserted.ARW", fingerprint: .stub("inserted")
        )
        lateInsert.metadata.captureDate = Date(timeIntervalSince1970: 1_600_000_000)
        try store.upsert(photo: lateInsert)

        var actual = firstPage.photos.map(\.id)
        var cursor = firstPage.nextCursor
        while let current = cursor {
            let page = try store.page(matching: query, after: current, limit: 4)
            actual.append(contentsOf: page.photos.map(\.id))
            cursor = page.nextCursor
        }

        let expected = Set(photos.map(\.id) + [lateInsert.id])
        XCTAssertEqual(Set(actual), expected)
        XCTAssertEqual(actual.count, Set(actual).count)
    }

    func testSourceScopeKeysetPagingAcrossMultiplePagesDoesNotLeakOtherLibraries() throws {
        let libraryA = try makeLibrary(name: "A")
        let libraryB = try makeLibrary(name: "B")

        var photosA: [PhotoAsset] = (0..<45).map { index -> PhotoAsset in
            var asset = PhotoAsset.stub(
                libraryID: libraryA.id, relativePath: "A/dated\(index).ARW", fingerprint: .stub("a-dated-\(index)")
            )
            asset.metadata.captureDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            return asset
        }
        let undatedA = (0..<5).map { index in
            PhotoAsset.stub(libraryID: libraryA.id, relativePath: "A/undated\(index).ARW", fingerprint: .stub("a-undated-\(index)"))
        }
        photosA.append(contentsOf: undatedA)
        try store.upsert(photos: photosA)

        // Library B interleaves dated rows across the same timestamps as A,
        // plus its own undated rows — neither must ever surface in A's pages.
        var photosB: [PhotoAsset] = (0..<45).map { index -> PhotoAsset in
            var asset = PhotoAsset.stub(
                libraryID: libraryB.id, relativePath: "B/dated\(index).ARW", fingerprint: .stub("b-dated-\(index)")
            )
            asset.metadata.captureDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            return asset
        }
        photosB.append(contentsOf: (0..<5).map { index in
            PhotoAsset.stub(libraryID: libraryB.id, relativePath: "B/undated\(index).ARW", fingerprint: .stub("b-undated-\(index)"))
        })
        try store.upsert(photos: photosB)

        let query = LibraryQuery(scope: .source(libraryA.id), sort: .captureDateDescending)
        var cursor: PhotoPageCursor?
        var actual: [PhotoID] = []
        repeat {
            let page = try store.page(matching: query, after: cursor, limit: 7)
            actual.append(contentsOf: page.photos.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil

        let datedSorted = photosA.filter { $0.metadata.captureDate != nil }
            .sorted { $0.metadata.captureDate! > $1.metadata.captureDate! }
        let undatedSorted = photosA.filter { $0.metadata.captureDate == nil }
            .sorted { $0.id.description < $1.id.description }
        let expected = (datedSorted + undatedSorted).map(\.id)

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(Set(actual).count, actual.count)
        XCTAssertTrue(Set(actual).isDisjoint(with: Set(photosB.map(\.id))))
    }

    func testFolderScopeKeysetPagingAcrossMultiplePagesDoesNotLeakSiblingsOrOtherLibraries() throws {
        let library = try makeLibrary()
        let otherLibrary = try makeLibrary(name: "Other")

        let inScope: [PhotoAsset] = (0..<30).map { index -> PhotoAsset in
            var asset = PhotoAsset.stub(
                libraryID: library.id,
                relativePath: index.isMultiple(of: 2) ? "TripA/dated\(index).ARW" : "TripA/Sub/dated\(index).ARW",
                fingerprint: .stub("in-\(index)")
            )
            asset.metadata.captureDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            return asset
        }
        try store.upsert(photos: inScope)

        let siblingPhotos = (0..<10).map { index in
            PhotoAsset.stub(libraryID: library.id, relativePath: "TripB/sibling\(index).ARW", fingerprint: .stub("sib-\(index)"))
        }
        try store.upsert(photos: siblingPhotos)

        let otherLibraryPhotos = (0..<10).map { index in
            PhotoAsset.stub(libraryID: otherLibrary.id, relativePath: "TripA/other\(index).ARW", fingerprint: .stub("other-\(index)"))
        }
        try store.upsert(photos: otherLibraryPhotos)

        let query = LibraryQuery(
            scope: .folder(libraryID: library.id, relativePath: "TripA"),
            sort: .captureDateDescending
        )
        var cursor: PhotoPageCursor?
        var actual: [PhotoID] = []
        repeat {
            let page = try store.page(matching: query, after: cursor, limit: 4)
            actual.append(contentsOf: page.photos.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil

        let expected = inScope.sorted { $0.metadata.captureDate! > $1.metadata.captureDate! }.map(\.id)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(Set(actual).count, actual.count)
        XCTAssertTrue(Set(actual).isDisjoint(with: Set((siblingPhotos + otherLibraryPhotos).map(\.id))))
    }

    func testCaptureDateAscendingKeysetPagingWithTiedDatesAndUndatedTail() throws {
        let library = try makeLibrary()
        let tiedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let tied = (0..<20).map { index -> PhotoAsset in
            var asset = PhotoAsset.stub(libraryID: library.id, relativePath: "tied\(index).ARW", fingerprint: .stub("asc-tied-\(index)"))
            asset.metadata.captureDate = tiedDate
            return asset
        }
        let laterDated = (0..<10).map { index -> PhotoAsset in
            var asset = PhotoAsset.stub(libraryID: library.id, relativePath: "later\(index).ARW", fingerprint: .stub("asc-later-\(index)"))
            asset.metadata.captureDate = Date(timeIntervalSince1970: 1_700_001_000 + Double(index))
            return asset
        }
        let undated = (0..<10).map { index in
            PhotoAsset.stub(libraryID: library.id, relativePath: "undated\(index).ARW", fingerprint: .stub("asc-undated-\(index)"))
        }
        try store.upsert(photos: tied + laterDated + undated)

        let query = LibraryQuery(scope: .all, sort: .captureDateAscending)
        var cursor: PhotoPageCursor?
        var actual: [PhotoID] = []
        repeat {
            let page = try store.page(matching: query, after: cursor, limit: 6)
            actual.append(contentsOf: page.photos.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil

        let expectedTied = tied.sorted { $0.id.description < $1.id.description }.map(\.id)
        let expectedLater = laterDated.sorted { $0.metadata.captureDate! < $1.metadata.captureDate! }.map(\.id)
        let expectedUndated = undated.sorted { $0.id.description < $1.id.description }.map(\.id)
        XCTAssertEqual(actual, expectedTied + expectedLater + expectedUndated)
        XCTAssertEqual(Set(actual).count, actual.count)
    }

    func testFilenameAscendingKeysetPagingWithTiedNormalizedFilename() throws {
        let library = try makeLibrary()
        let alphaGroup = (0..<15).map { index -> PhotoAsset in
            PhotoAsset.stub(libraryID: library.id, relativePath: "DirA\(index)/Alpha.ARW", fingerprint: .stub("fn-asc-a-\(index)"))
        }
        let zuluGroup = (0..<15).map { index -> PhotoAsset in
            PhotoAsset.stub(libraryID: library.id, relativePath: "DirZ\(index)/Zulu.ARW", fingerprint: .stub("fn-asc-z-\(index)"))
        }
        try store.upsert(photos: alphaGroup + zuluGroup)

        let query = LibraryQuery(scope: .all, sort: .filenameAscending)
        var cursor: PhotoPageCursor?
        var actual: [PhotoID] = []
        repeat {
            let page = try store.page(matching: query, after: cursor, limit: 6)
            actual.append(contentsOf: page.photos.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil

        let expected = alphaGroup.sorted { $0.id.description < $1.id.description }.map(\.id)
            + zuluGroup.sorted { $0.id.description < $1.id.description }.map(\.id)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(Set(actual).count, actual.count)
    }

    func testFilenameDescendingKeysetPagingWithTiedNormalizedFilename() throws {
        let library = try makeLibrary()
        let alphaGroup = (0..<15).map { index -> PhotoAsset in
            PhotoAsset.stub(libraryID: library.id, relativePath: "DirA\(index)/Alpha.ARW", fingerprint: .stub("fn-desc-a-\(index)"))
        }
        let zuluGroup = (0..<15).map { index -> PhotoAsset in
            PhotoAsset.stub(libraryID: library.id, relativePath: "DirZ\(index)/Zulu.ARW", fingerprint: .stub("fn-desc-z-\(index)"))
        }
        try store.upsert(photos: alphaGroup + zuluGroup)

        let query = LibraryQuery(scope: .all, sort: .filenameDescending)
        var cursor: PhotoPageCursor?
        var actual: [PhotoID] = []
        repeat {
            let page = try store.page(matching: query, after: cursor, limit: 6)
            actual.append(contentsOf: page.photos.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil

        let expected = zuluGroup.sorted { $0.id.description < $1.id.description }.map(\.id)
            + alphaGroup.sorted { $0.id.description < $1.id.description }.map(\.id)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(Set(actual).count, actual.count)
    }

    func testRecentlyEditedKeysetPagingWithTiedLastEditDateIgnoresRequestedSort() throws {
        let library = try makeLibrary()
        let tiedEditDate = Date(timeIntervalSince1970: 1_700_000_500)
        let edited = (0..<20).map { index -> PhotoAsset in
            PhotoAsset.stub(libraryID: library.id, relativePath: "edited\(index).ARW", fingerprint: .stub("re-\(index)"))
        }
        try store.upsert(photos: edited)
        for photo in edited {
            try store.setEditState(for: photo.id, hasEdits: true, lastEditAt: tiedEditDate)
        }
        let untouched = (0..<5).map { index in
            PhotoAsset.stub(libraryID: library.id, relativePath: "untouched\(index).ARW", fingerprint: .stub("re-untouched-\(index)"))
        }
        try store.upsert(photos: untouched)

        // Requested sort is filenameDescending; .recentlyEdited must ignore
        // it and order by last_edit_at DESC / PhotoID ASC on ties, and must
        // never surface the untouched photos.
        let query = LibraryQuery(scope: .recentlyEdited, sort: .filenameDescending)
        var cursor: PhotoPageCursor?
        var actual: [PhotoID] = []
        repeat {
            let page = try store.page(matching: query, after: cursor, limit: 6)
            actual.append(contentsOf: page.photos.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil

        let expected = edited.sorted { $0.id.description < $1.id.description }.map(\.id)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(Set(actual).count, actual.count)
        XCTAssertTrue(Set(actual).isDisjoint(with: Set(untouched.map(\.id))))
    }

    // MARK: - Scopes

    func testSourceScopeOnlyReturnsThatLibrarysPhotos() throws {
        let libraryA = try makeLibrary(name: "A")
        let libraryB = try makeLibrary(name: "B")
        try store.upsert(photo: PhotoAsset.stub(libraryID: libraryA.id, relativePath: "a.ARW", fingerprint: .stub("a")))
        try store.upsert(photo: PhotoAsset.stub(libraryID: libraryB.id, relativePath: "b.ARW", fingerprint: .stub("b")))

        let page = try store.page(
            matching: LibraryQuery(scope: .source(libraryA.id), sort: .captureDateDescending),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(page.photos.map(\.relativePath), ["a.ARW"])
    }

    func testFolderScopeIncludesDescendantsButNotSiblings() throws {
        let library = try makeLibrary()
        try store.upsert(photos: [
            PhotoAsset.stub(libraryID: library.id, relativePath: "TripA/file1.ARW", fingerprint: .stub("1")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "TripA/Sub/file2.ARW", fingerprint: .stub("2")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "TripB/file3.ARW", fingerprint: .stub("3")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "root.ARW", fingerprint: .stub("4"))
        ])

        let page = try store.page(
            matching: LibraryQuery(
                scope: .folder(libraryID: library.id, relativePath: "TripA"),
                sort: .filenameAscending
            ),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(Set(page.photos.map(\.relativePath)), ["TripA/file1.ARW", "TripA/Sub/file2.ARW"])

        let rootPage = try store.page(
            matching: LibraryQuery(
                scope: .folder(libraryID: library.id, relativePath: ""),
                sort: .filenameAscending
            ),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(rootPage.photos.count, 4)
    }

    func testFolderScopeEscapesLikeWildcardsInDirectoryNames() throws {
        let library = try makeLibrary()
        try store.upsert(photos: [
            PhotoAsset.stub(libraryID: library.id, relativePath: "50%_off/keep.ARW", fingerprint: .stub("keep")),
            // Without escaping, the unescaped LIKE pattern "50%_off/%" would
            // spuriously match this unrelated directory too.
            PhotoAsset.stub(libraryID: library.id, relativePath: "50XYZQoff/decoy.ARW", fingerprint: .stub("decoy"))
        ])

        let page = try store.page(
            matching: LibraryQuery(
                scope: .folder(libraryID: library.id, relativePath: "50%_off"),
                sort: .filenameAscending
            ),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(page.photos.map(\.relativePath), ["50%_off/keep.ARW"])
    }

    func testFolderScopeIsCaseSensitiveAndDoesNotMatchSimilarPrefixes() throws {
        let library = try makeLibrary()
        try store.upsert(photos: [
            PhotoAsset.stub(libraryID: library.id, relativePath: "Trip/keep.ARW", fingerprint: .stub("keep")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "Trip/Sub/keep2.ARW", fingerprint: .stub("keep2")),
            // SQLite's default LIKE is ASCII case-insensitive, so a
            // pre-fix `LIKE 'Trip/%'` prefix check would treat this nested
            // "trip/Sub" directory as a descendant of "Trip" — it must not.
            // (A direct, non-nested "trip/..." decoy wouldn't exercise this:
            // its directory is just "trip", which lacks the trailing "/"
            // the LIKE prefix requires, so it fails on length alone.)
            PhotoAsset.stub(libraryID: library.id, relativePath: "trip/Sub/decoy.ARW", fingerprint: .stub("decoy-case")),
            // A similar but distinct top-level name must not match either.
            PhotoAsset.stub(libraryID: library.id, relativePath: "Trip2/decoy.ARW", fingerprint: .stub("decoy-prefix"))
        ])

        let page = try store.page(
            matching: LibraryQuery(
                scope: .folder(libraryID: library.id, relativePath: "Trip"),
                sort: .filenameAscending
            ),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(
            Set(page.photos.map(\.relativePath)), ["Trip/keep.ARW", "Trip/Sub/keep2.ARW"]
        )
    }

    func testChildDirectoriesIsCaseSensitiveAndDoesNotMatchSimilarPrefixes() throws {
        let library = try makeLibrary()
        try store.upsert(photos: [
            PhotoAsset.stub(libraryID: library.id, relativePath: "Trip/keep.ARW", fingerprint: .stub("keep")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "Trip/Sub/keep2.ARW", fingerprint: .stub("keep2")),
            // A pre-fix case-insensitive LIKE prefix check would fold this
            // nested "trip/Sub" directory into "Trip"'s descendant set.
            PhotoAsset.stub(libraryID: library.id, relativePath: "trip/Sub/decoy.ARW", fingerprint: .stub("decoy-case")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "Trip2/decoy.ARW", fingerprint: .stub("decoy-prefix"))
        ])

        let atRoot = try store.childDirectories(libraryID: library.id, parent: "")
        XCTAssertEqual(Set(atRoot.map(\.relativePath)), ["Trip", "trip", "Trip2"])

        let underTrip = try store.childDirectories(libraryID: library.id, parent: "Trip")
        XCTAssertEqual(underTrip.map(\.relativePath), ["Trip/Sub"])
        XCTAssertEqual(underTrip.first?.childCount, 1)
    }

    func testChildDirectoriesHandlesSpecialCharactersInNestedParent() throws {
        let library = try makeLibrary()
        try store.upsert(photos: [
            PhotoAsset.stub(libraryID: library.id, relativePath: "Trip\\A/Sub/keep.ARW", fingerprint: .stub("keep")),
            PhotoAsset.stub(
                libraryID: library.id, relativePath: "Trip\\A/decoy-direct.ARW", fingerprint: .stub("decoy-direct")
            ),
            // A sibling whose name is similar once the backslash is dropped
            // must not be treated as a descendant of "Trip\A".
            PhotoAsset.stub(libraryID: library.id, relativePath: "TripXA/decoy.ARW", fingerprint: .stub("decoy-sibling"))
        ])

        let children = try store.childDirectories(libraryID: library.id, parent: "Trip\\A")
        XCTAssertEqual(children.map(\.relativePath), ["Trip\\A/Sub"])
        XCTAssertEqual(children.first?.displayName, "Sub")
        XCTAssertEqual(children.first?.childCount, 1)
    }

    func testChildDirectoriesHandlesSpecialCharactersAtNestedDepth() throws {
        let library = try makeLibrary()
        try store.upsert(photos: [
            // "%"/"_" in a nested parent name must be treated as literal
            // path characters, not LIKE wildcards, at every depth.
            PhotoAsset.stub(libraryID: library.id, relativePath: "50%_off/Sub/keep.ARW", fingerprint: .stub("percent-keep")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "50XYZQoff/Sub/decoy.ARW", fingerprint: .stub("percent-decoy")),
            // Multi-byte Unicode parent name.
            PhotoAsset.stub(libraryID: library.id, relativePath: "資料夾/Sub/keep.ARW", fingerprint: .stub("unicode-keep")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "資料夾2/Sub/decoy.ARW", fingerprint: .stub("unicode-decoy")),
            // ASCII case-distinct and similar-prefix decoys.
            PhotoAsset.stub(libraryID: library.id, relativePath: "CaseTrip/Sub/keep.ARW", fingerprint: .stub("case-keep")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "casetrip/Sub/decoy.ARW", fingerprint: .stub("case-decoy")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "CaseTrip2/Sub/decoy.ARW", fingerprint: .stub("case-decoy2"))
        ])

        let cases: [(parent: String, expectedChild: String)] = [
            ("50%_off", "50%_off/Sub"),
            ("資料夾", "資料夾/Sub"),
            ("CaseTrip", "CaseTrip/Sub")
        ]
        for testCase in cases {
            let children = try store.childDirectories(libraryID: library.id, parent: testCase.parent)
            XCTAssertEqual(
                children.map(\.relativePath), [testCase.expectedChild],
                "parent \(testCase.parent) leaked a decoy or missed its real child"
            )
            XCTAssertEqual(children.first?.childCount, 1)
        }
    }

    func testFolderScopeAndChildDirectoriesEscapeLiteralBackslashInDirectoryNames() throws {
        let library = try makeLibrary()
        try store.upsert(photos: [
            PhotoAsset.stub(libraryID: library.id, relativePath: "Trip\\A/keep.ARW", fingerprint: .stub("keep")),
            // Without escaping, the unescaped LIKE pattern "Trip\A/%" would
            // interpret `\A` as an (invalid) escape sequence rather than
            // literal characters, and could spuriously match this decoy.
            PhotoAsset.stub(libraryID: library.id, relativePath: "TripXA/decoy.ARW", fingerprint: .stub("decoy"))
        ])

        let page = try store.page(
            matching: LibraryQuery(
                scope: .folder(libraryID: library.id, relativePath: "Trip\\A"),
                sort: .filenameAscending
            ),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(page.photos.map(\.relativePath), ["Trip\\A/keep.ARW"])

        let children = try store.childDirectories(libraryID: library.id, parent: "")
        XCTAssertEqual(Set(children.map(\.relativePath)), ["Trip\\A", "TripXA"])
        let backslashChild = try XCTUnwrap(children.first { $0.relativePath == "Trip\\A" })
        XCTAssertEqual(backslashChild.displayName, "Trip\\A")
        XCTAssertEqual(backslashChild.childCount, 1)
    }

    func testAppStorageScopeOnlyReturnsAppStorageLibraries() throws {
        let externalLibrary = try makeLibrary(name: "External")
        let appStorageLibrary = try makeLibrary(name: "AppStorage")
        try markSourceKind("appStorage", for: appStorageLibrary.id)
        try store.upsert(photos: [
            PhotoAsset.stub(libraryID: externalLibrary.id, relativePath: "ext.ARW", fingerprint: .stub("ext")),
            PhotoAsset.stub(libraryID: appStorageLibrary.id, relativePath: "app.ARW", fingerprint: .stub("app"))
        ])

        let page = try store.page(
            matching: LibraryQuery(scope: .appStorage, sort: .captureDateDescending),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(page.photos.map(\.relativePath), ["app.ARW"])
    }

    func testRecentlyEditedScopeOrdersByLastEditDescendingRegardlessOfRequestedSort() throws {
        let library = try makeLibrary()
        var edited1 = PhotoAsset.stub(libraryID: library.id, relativePath: "e1.ARW", fingerprint: .stub("e1"))
        var edited2 = PhotoAsset.stub(libraryID: library.id, relativePath: "e2.ARW", fingerprint: .stub("e2"))
        let untouched = PhotoAsset.stub(libraryID: library.id, relativePath: "u.ARW", fingerprint: .stub("u"))
        try store.upsert(photos: [edited1, edited2, untouched])

        try store.setEditState(
            for: edited1.id, hasEdits: true, lastEditAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try store.setEditState(
            for: edited2.id, hasEdits: true, lastEditAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        // Requested sort is ascending filename, but .recentlyEdited must
        // still order by last_edit_at DESC.
        let page = try store.page(
            matching: LibraryQuery(scope: .recentlyEdited, sort: .filenameAscending),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(page.photos.map(\.relativePath), ["e2.ARW", "e1.ARW"])
        edited1.lastEditAt = nil
        edited2.lastEditAt = nil
    }

    // MARK: - Sorts and NULL handling

    func testCaptureDateAscendingAndDescendingOrderCorrectly() throws {
        let library = try makeLibrary()
        func photo(_ name: String, _ time: TimeInterval) -> PhotoAsset {
            var asset = PhotoAsset.stub(libraryID: library.id, relativePath: name, fingerprint: .stub(name))
            asset.metadata.captureDate = Date(timeIntervalSince1970: time)
            return asset
        }
        try store.upsert(photos: [photo("c.ARW", 300), photo("a.ARW", 100), photo("b.ARW", 200)])

        let ascending = try store.page(
            matching: LibraryQuery(scope: .all, sort: .captureDateAscending), after: nil, limit: 10
        )
        XCTAssertEqual(ascending.photos.map(\.relativePath), ["a.ARW", "b.ARW", "c.ARW"])

        let descending = try store.page(
            matching: LibraryQuery(scope: .all, sort: .captureDateDescending), after: nil, limit: 10
        )
        XCTAssertEqual(descending.photos.map(\.relativePath), ["c.ARW", "b.ARW", "a.ARW"])
    }

    func testFilenameSortsAscendingAndDescending() throws {
        let library = try makeLibrary()
        try store.upsert(photos: [
            PhotoAsset.stub(libraryID: library.id, relativePath: "banana.ARW", fingerprint: .stub("banana")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "apple.ARW", fingerprint: .stub("apple")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "cherry.ARW", fingerprint: .stub("cherry"))
        ])

        let ascending = try store.page(
            matching: LibraryQuery(scope: .all, sort: .filenameAscending), after: nil, limit: 10
        )
        XCTAssertEqual(ascending.photos.map(\.relativePath), ["apple.ARW", "banana.ARW", "cherry.ARW"])

        let descending = try store.page(
            matching: LibraryQuery(scope: .all, sort: .filenameDescending), after: nil, limit: 10
        )
        XCTAssertEqual(descending.photos.map(\.relativePath), ["cherry.ARW", "banana.ARW", "apple.ARW"])
    }

    func testPhotosWithoutCaptureDateSortLastInBothDirections() throws {
        let library = try makeLibrary()
        var dated = PhotoAsset.stub(libraryID: library.id, relativePath: "dated.ARW", fingerprint: .stub("dated"))
        dated.metadata.captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        let undated = PhotoAsset.stub(libraryID: library.id, relativePath: "undated.ARW", fingerprint: .stub("undated"))
        try store.upsert(photos: [dated, undated])

        let ascending = try store.page(
            matching: LibraryQuery(scope: .all, sort: .captureDateAscending), after: nil, limit: 10
        )
        XCTAssertEqual(ascending.photos.map(\.relativePath), ["dated.ARW", "undated.ARW"])

        let descending = try store.page(
            matching: LibraryQuery(scope: .all, sort: .captureDateDescending), after: nil, limit: 10
        )
        XCTAssertEqual(descending.photos.map(\.relativePath), ["dated.ARW", "undated.ARW"])
    }

    func testUndatedPhotosPageCorrectlyAfterAllDatedPhotosAreExhausted() throws {
        let library = try makeLibrary()
        var dated = (0..<3).map { index -> PhotoAsset in
            var asset = PhotoAsset.stub(
                libraryID: library.id, relativePath: "dated\(index).ARW", fingerprint: .stub("dated\(index)")
            )
            asset.metadata.captureDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            return asset
        }
        let undated = (0..<3).map { index in
            PhotoAsset.stub(
                libraryID: library.id, relativePath: "undated\(index).ARW", fingerprint: .stub("undated\(index)")
            )
        }
        try store.upsert(photos: dated + undated)

        let query = LibraryQuery(scope: .all, sort: .captureDateDescending)
        var cursor: PhotoPageCursor?
        var actual: [String] = []
        repeat {
            let page = try store.page(matching: query, after: cursor, limit: 2)
            actual.append(contentsOf: page.photos.map(\.relativePath))
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(Set(actual), Set((dated + undated).map(\.relativePath)))
        XCTAssertEqual(actual.count, 6)
        XCTAssertEqual(Set(actual.prefix(3)), Set(dated.map(\.relativePath)))
        dated = []
    }

    // MARK: - Filename search

    func testFilenameSearchIsUnicodeNormalizedSubstringMatch() throws {
        let library = try makeLibrary()
        try store.upsert(photo: PhotoAsset.stub(
            libraryID: library.id, relativePath: "Trip/Café.ARW", fingerprint: .stub("cafe")
        ))

        // "Café" using a combining acute accent (decomposed) must still find
        // the precomposed spelling stored on disk, and vice versa.
        let decomposedSearch = try store.page(
            matching: LibraryQuery(scope: .all, filenameSearch: "cafe\u{0301}", sort: .filenameAscending),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(decomposedSearch.photos.count, 1)

        let caseInsensitiveSearch = try store.page(
            matching: LibraryQuery(scope: .all, filenameSearch: "CAFÉ", sort: .filenameAscending),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(caseInsensitiveSearch.photos.count, 1)

        let noMatch = try store.page(
            matching: LibraryQuery(scope: .all, filenameSearch: "zzz", sort: .filenameAscending),
            after: nil,
            limit: 10
        )
        XCTAssertTrue(noMatch.photos.isEmpty)
    }

    func testFilenameSearchTreatsPercentUnderscoreAndBackslashAsLiteralCharacters() throws {
        let library = try makeLibrary()
        try store.upsert(photos: [
            PhotoAsset.stub(libraryID: library.id, relativePath: "50%off.ARW", fingerprint: .stub("percent")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "aXc.ARW", fingerprint: .stub("underscore-decoy")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "a_c.ARW", fingerprint: .stub("underscore"))
        ])

        let percentSearch = try store.page(
            matching: LibraryQuery(scope: .all, filenameSearch: "50%off", sort: .filenameAscending),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(percentSearch.photos.map(\.relativePath), ["50%off.ARW"])

        // "_" must not act as a single-character wildcard: only "a_c" (the
        // literal match) comes back, not the "aXc" decoy.
        let underscoreSearch = try store.page(
            matching: LibraryQuery(scope: .all, filenameSearch: "a_c", sort: .filenameAscending),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(underscoreSearch.photos.map(\.relativePath), ["a_c.ARW"])
    }

    func testFilenameSearchTreatsLiteralBackslashAsAnOrdinaryCharacter() throws {
        let library = try makeLibrary()
        try store.upsert(photos: [
            PhotoAsset.stub(libraryID: library.id, relativePath: "a\\b.ARW", fingerprint: .stub("backslash")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "ab.ARW", fingerprint: .stub("no-backslash-decoy"))
        ])

        // The escape character itself, `\`, must be searchable as a literal
        // character rather than being swallowed as a LIKE escape prefix.
        let page = try store.page(
            matching: LibraryQuery(scope: .all, filenameSearch: "a\\b", sort: .filenameAscending),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(page.photos.map(\.relativePath), ["a\\b.ARW"])
    }

    // MARK: - Cursor shape validation

    func testFilenameCursorIsRejectedForCaptureDateSort() throws {
        let library = try makeLibrary()
        try store.upsert(photo: PhotoAsset.stub(libraryID: library.id, relativePath: "a.ARW", fingerprint: .stub("a")))

        // Shape is dateKey == nil / filenameKey != nil. Before this fix the
        // capture-date branch only checked dateKey, so this cursor was
        // silently treated as a legitimate "NULL-capture" cursor and every
        // dated row was skipped instead of the lookup being rejected.
        let filenameCursor = PhotoPageCursor(filenameKey: "a.arw", photoID: PhotoID())
        XCTAssertThrowsError(
            try store.page(
                matching: LibraryQuery(scope: .all, sort: .captureDateDescending),
                after: filenameCursor,
                limit: 10
            )
        ) { error in
            XCTAssertEqual(error as? LibraryQueryError, .invalidCursor)
        }
        XCTAssertThrowsError(
            try store.page(
                matching: LibraryQuery(scope: .all, sort: .captureDateAscending),
                after: filenameCursor,
                limit: 10
            )
        ) { error in
            XCTAssertEqual(error as? LibraryQueryError, .invalidCursor)
        }
    }

    func testDatedCaptureCursorIsRejectedForFilenameSort() throws {
        let library = try makeLibrary()
        try store.upsert(photo: PhotoAsset.stub(libraryID: library.id, relativePath: "a.ARW", fingerprint: .stub("a")))

        let captureCursor = PhotoPageCursor(
            dateKey: Date(timeIntervalSince1970: 1_700_000_000), photoID: PhotoID()
        )
        XCTAssertThrowsError(
            try store.page(
                matching: LibraryQuery(scope: .all, sort: .filenameAscending),
                after: captureCursor,
                limit: 10
            )
        ) { error in
            XCTAssertEqual(error as? LibraryQueryError, .invalidCursor)
        }
    }

    func testFilenameCursorIsRejectedForRecentlyEditedSort() throws {
        let library = try makeLibrary()
        try store.upsert(photo: PhotoAsset.stub(libraryID: library.id, relativePath: "a.ARW", fingerprint: .stub("a")))

        let filenameCursor = PhotoPageCursor(filenameKey: "a.arw", photoID: PhotoID())
        XCTAssertThrowsError(
            try store.page(
                matching: LibraryQuery(scope: .recentlyEdited, sort: .filenameAscending),
                after: filenameCursor,
                limit: 10
            )
        ) { error in
            XCTAssertEqual(error as? LibraryQueryError, .invalidCursor)
        }
    }

    func testCursorCarryingBothDateAndFilenameKeysIsAlwaysRejected() throws {
        let library = try makeLibrary()
        try store.upsert(photo: PhotoAsset.stub(libraryID: library.id, relativePath: "a.ARW", fingerprint: .stub("a")))

        let ambiguousCursor = PhotoPageCursor(
            dateKey: Date(timeIntervalSince1970: 1_700_000_000), filenameKey: "a.arw", photoID: PhotoID()
        )
        let sorts: [PhotoSort] = [
            .captureDateDescending, .captureDateAscending, .filenameAscending, .filenameDescending
        ]
        for sort in sorts {
            XCTAssertThrowsError(
                try store.page(
                    matching: LibraryQuery(scope: .all, sort: sort), after: ambiguousCursor, limit: 10
                )
            ) { error in
                XCTAssertEqual(error as? LibraryQueryError, .invalidCursor)
            }
        }
        XCTAssertThrowsError(
            try store.page(
                matching: LibraryQuery(scope: .recentlyEdited, sort: .captureDateDescending),
                after: ambiguousCursor,
                limit: 10
            )
        ) { error in
            XCTAssertEqual(error as? LibraryQueryError, .invalidCursor)
        }
    }

    // MARK: - Limit validation

    func testPageLimitIsRejectedOutsideValidRange() throws {
        let query = LibraryQuery(scope: .all, sort: .captureDateDescending)
        XCTAssertThrowsError(try store.page(matching: query, after: nil, limit: 0)) { error in
            XCTAssertEqual(error as? LibraryQueryError, .invalidLimit(0))
        }
        XCTAssertThrowsError(try store.page(matching: query, after: nil, limit: 201)) { error in
            XCTAssertEqual(error as? LibraryQueryError, .invalidLimit(201))
        }
        XCTAssertNoThrow(try store.page(matching: query, after: nil, limit: 1))
        XCTAssertNoThrow(try store.page(matching: query, after: nil, limit: 200))
    }

    // MARK: - Lazy child-directory listing

    func testChildDirectoriesListsImmediateChildrenLazily() throws {
        let library = try makeLibrary()
        try store.upsert(photos: [
            PhotoAsset.stub(libraryID: library.id, relativePath: "root.ARW", fingerprint: .stub("root")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "Trip/a.ARW", fingerprint: .stub("a")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "Trip/Sub/b.ARW", fingerprint: .stub("b")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "Trip/Sub/c.ARW", fingerprint: .stub("c")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "Other/d.ARW", fingerprint: .stub("d"))
        ])

        let atRoot = try store.childDirectories(libraryID: library.id, parent: "")
        XCTAssertEqual(Set(atRoot.map(\.relativePath)), ["Trip", "Other"])
        let trip = try XCTUnwrap(atRoot.first { $0.relativePath == "Trip" })
        // "Sub" isn't listed at this depth — only immediate children.
        XCTAssertEqual(trip.displayName, "Trip")
        XCTAssertEqual(trip.childCount, 3) // a.ARW + Sub/b.ARW + Sub/c.ARW

        let underTrip = try store.childDirectories(libraryID: library.id, parent: "Trip")
        XCTAssertEqual(underTrip.map(\.relativePath), ["Trip/Sub"])
        XCTAssertEqual(underTrip.first?.childCount, 2)

        let underSub = try store.childDirectories(libraryID: library.id, parent: "Trip/Sub")
        XCTAssertTrue(underSub.isEmpty)
    }

    func testChildDirectoriesQueryDoesNotMaterializeEveryDescendantDirectory() throws {
        // 6 immediate children at root, each with 30 distinct nested
        // descendant directories two levels deep: 180 distinct
        // `relative_directory` values total, but only 6 immediate children.
        // A query that first fetches every descendant directory row and
        // folds them in Swift would report a raw SQL row count of 180; the
        // required immediate-child-bounded query reports 6.
        let hookedURL = temporaryDirectory.appendingPathComponent("child-dirs-cardinality.sqlite")
        var rawRowCount: Int?
        let hookedStore = try PhotoIndexStore(
            databaseURL: hookedURL,
            migrationHook: {},
            childDirectoriesRawRowCountHook: { rawRowCount = $0 }
        )
        defer { hookedStore.close() }

        let library = LibraryFolder(
            displayName: "Cardinality",
            rootURL: URL(fileURLWithPath: "/Volumes/Cardinality", isDirectory: true)
        )
        try hookedStore.upsert(library: library)

        var photos: [PhotoAsset] = []
        for child in 0..<6 {
            for nested in 0..<30 {
                photos.append(PhotoAsset.stub(
                    libraryID: library.id,
                    relativePath: "Child\(child)/Nested\(nested)/leaf.ARW",
                    fingerprint: .stub("c\(child)-n\(nested)")
                ))
            }
        }
        try hookedStore.upsert(photos: photos)

        let atRoot = try hookedStore.childDirectories(libraryID: library.id, parent: "")

        XCTAssertEqual(atRoot.count, 6)
        XCTAssertEqual(
            rawRowCount, 6,
            "SQL must return one row per immediate child, not one per descendant directory"
        )
    }

    func testChildDirectoriesEscapesWildcardsAndHandlesUnicodeNames() throws {
        let library = try makeLibrary()
        try store.upsert(photos: [
            PhotoAsset.stub(libraryID: library.id, relativePath: "50%_off/keep.ARW", fingerprint: .stub("keep")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "50XYZQoff/decoy.ARW", fingerprint: .stub("decoy")),
            PhotoAsset.stub(libraryID: library.id, relativePath: "資料夾/photo.ARW", fingerprint: .stub("unicode"))
        ])

        let atRoot = try store.childDirectories(libraryID: library.id, parent: "")
        XCTAssertEqual(
            Set(atRoot.map(\.relativePath)), ["50%_off", "50XYZQoff", "資料夾"]
        )
        let percentNode = try XCTUnwrap(atRoot.first { $0.relativePath == "50%_off" })
        XCTAssertEqual(percentNode.childCount, 1)
        let unicodeNode = try XCTUnwrap(atRoot.first { $0.relativePath == "資料夾" })
        XCTAssertEqual(unicodeNode.displayName, "資料夾")
    }

    // MARK: - Edit state

    func testSetEditStateStoresNonNeutralEditThenClearsOnNeutralSave() throws {
        let library = try makeLibrary()
        let photo = PhotoAsset.stub(libraryID: library.id, relativePath: "edit.ARW", fingerprint: .stub("edit"))
        try store.upsert(photo: photo)

        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_500)
        try store.setEditState(for: photo.id, hasEdits: true, lastEditAt: modifiedAt)
        var loaded = try XCTUnwrap(try store.photo(id: photo.id))
        XCTAssertEqual(loaded.hasEdits, true)
        XCTAssertEqual(loaded.lastEditAt?.timeIntervalSince1970 ?? -1, modifiedAt.timeIntervalSince1970, accuracy: 0.001)

        // A neutral save clears both fields together.
        try store.setEditState(for: photo.id, hasEdits: false, lastEditAt: nil)
        loaded = try XCTUnwrap(try store.photo(id: photo.id))
        XCTAssertEqual(loaded.hasEdits, false)
        XCTAssertNil(loaded.lastEditAt)
    }

    func testSetEditStateThrowsWhenHasEditsTrueWithNoDate() throws {
        let library = try makeLibrary()
        let photo = PhotoAsset.stub(libraryID: library.id, relativePath: "invalid.ARW", fingerprint: .stub("invalid"))
        try store.upsert(photo: photo)

        XCTAssertThrowsError(try store.setEditState(for: photo.id, hasEdits: true, lastEditAt: nil)) { error in
            XCTAssertEqual(error as? LibraryQueryError, .missingEditDate)
        }

        // The rejected write must not have touched the row at all.
        let loaded = try XCTUnwrap(try store.photo(id: photo.id))
        XCTAssertEqual(loaded.hasEdits, false)
        XCTAssertNil(loaded.lastEditAt)
    }

    func testSetEditStateForcesLastEditAtNilWhenHasEditsIsFalseEvenIfCallerPassesADate() throws {
        let library = try makeLibrary()
        let photo = PhotoAsset.stub(
            libraryID: library.id, relativePath: "contradictory.ARW", fingerprint: .stub("contradictory")
        )
        try store.upsert(photo: photo)

        // A caller passing a stale non-nil date alongside hasEdits: false
        // must not be able to write the contradictory (false, non-nil) row.
        try store.setEditState(
            for: photo.id, hasEdits: false, lastEditAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let loaded = try XCTUnwrap(try store.photo(id: photo.id))
        XCTAssertEqual(loaded.hasEdits, false)
        XCTAssertNil(loaded.lastEditAt)
    }

    // MARK: - Curation snapshot and migration-pending flag

    func testCurationSnapshotReturnsOnlyRowsThatHaveNonDefaultData() throws {
        let library = try makeLibrary()
        let rated = PhotoAsset.stub(libraryID: library.id, relativePath: "Rated.ARW", fingerprint: .stub("rated"))
        let untouched = PhotoAsset.stub(libraryID: library.id, relativePath: "Untouched.ARW", fingerprint: .stub("untouched"))
        try store.upsert(photos: [rated, untouched])
        try store.setRating(4, for: rated.id)

        let snapshot = try store.curationSnapshot(inLibrary: library.id)

        XCTAssertEqual(snapshot[rated.id]?.rating, 4)
        XCTAssertEqual(snapshot[PhotoID()], nil)
    }

    func testCurationSnapshotIncludesFlagAndKeywords() throws {
        let library = try makeLibrary()
        let photo = PhotoAsset.stub(libraryID: library.id, relativePath: "Tagged.ARW", fingerprint: .stub("tagged"))
        try store.upsert(photo: photo)
        try store.setFlag(.pick, for: photo.id)
        try store.setKeywords(["Dog", "Beach"], for: photo.id)

        let snapshot = try store.curationSnapshot(inLibrary: library.id)

        XCTAssertEqual(snapshot[photo.id]?.flag, .pick)
        XCTAssertEqual(Set(snapshot[photo.id]?.keywords.map(\.displayValue) ?? []), ["Dog", "Beach"])
    }

    func testCurationSnapshotOnlyIncludesTheGivenLibrary() throws {
        let libraryA = try makeLibrary(name: "A")
        let libraryB = try makeLibrary(name: "B")
        let photoA = PhotoAsset.stub(libraryID: libraryA.id, relativePath: "A.ARW", fingerprint: .stub("a"))
        let photoB = PhotoAsset.stub(libraryID: libraryB.id, relativePath: "B.ARW", fingerprint: .stub("b"))
        try store.upsert(photos: [photoA, photoB])
        try store.setRating(3, for: photoA.id)
        try store.setRating(5, for: photoB.id)

        let snapshot = try store.curationSnapshot(inLibrary: libraryA.id)

        XCTAssertEqual(snapshot[photoA.id]?.rating, 3)
        XCTAssertNil(snapshot[photoB.id])
    }

    func testSetCurationMigrationPendingRoundTrips() throws {
        let library = try makeLibrary()
        let photo = PhotoAsset.stub(libraryID: library.id, relativePath: "Pending.ARW", fingerprint: .stub("pending"))
        try store.upsert(photo: photo)
        XCTAssertEqual(try store.photo(id: photo.id)?.curationMigrationPending, false)

        try store.setCurationMigrationPending(true, for: photo.id)
        XCTAssertEqual(try store.photo(id: photo.id)?.curationMigrationPending, true)

        try store.setCurationMigrationPending(false, for: photo.id)
        XCTAssertEqual(try store.photo(id: photo.id)?.curationMigrationPending, false)
    }

    func testRescanDoesNotClearCurationMigrationPendingByItself() throws {
        // Mirrors the existing rating/flag ON CONFLICT exclusion: only an
        // explicit call may change this flag, never a plain rescan upsert.
        let library = try makeLibrary()
        let photo = PhotoAsset.stub(libraryID: library.id, relativePath: "Rescan.ARW", fingerprint: .stub("rescan"))
        try store.upsert(photo: photo)
        try store.setCurationMigrationPending(true, for: photo.id)

        try store.upsert(photo: photo)

        XCTAssertEqual(try store.photo(id: photo.id)?.curationMigrationPending, true)
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeLibrary(name: String = "Library") throws -> LibraryFolder {
        let library = LibraryFolder(
            displayName: name,
            rootURL: URL(fileURLWithPath: "/Volumes/\(name)", isDirectory: true)
        )
        try store.upsert(library: library)
        return library
    }

    private func markSourceKind(_ sourceKind: String, for libraryID: LibraryID) throws {
        let raw = try SQLiteDatabase(url: databaseURL)
        defer { raw.close() }
        try raw.run(
            "UPDATE library SET source_kind = ? WHERE id = ?;",
            [.text(sourceKind), .text(libraryID.description)]
        )
    }

    private func seedThreeLibraries(photoCountPerLibrary: Int) throws -> [PhotoID] {
        var allPhotos: [PhotoAsset] = []
        for librarySeed in 0..<3 {
            let library = try makeLibrary(name: "Library\(librarySeed)")
            for index in 0..<photoCountPerLibrary {
                var asset = PhotoAsset.stub(
                    libraryID: library.id,
                    relativePath: "L\(librarySeed)/DSC\(index).ARW",
                    fingerprint: .stub("l\(librarySeed)-\(index)")
                )
                let globalIndex = librarySeed * photoCountPerLibrary + index
                asset.metadata.captureDate = Date(
                    timeIntervalSince1970: 1_700_000_000 + Double(globalIndex)
                )
                allPhotos.append(asset)
            }
        }
        try store.upsert(photos: allPhotos)
        return allPhotos
            .sorted { $0.metadata.captureDate! > $1.metadata.captureDate! }
            .map(\.id)
    }
}
