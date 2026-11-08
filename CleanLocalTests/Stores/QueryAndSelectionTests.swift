import XCTest
@testable import CleanLocal

final class MediaQueryTests: XCTestCase {
    private let items = [
        makeItem(id: "a", path: "/p/Beach.jpg", format: .jpeg, size: 300, created: Date(timeIntervalSince1970: 300)),
        makeItem(id: "b", path: "/p/clip.mov", format: .mov, size: 900, created: Date(timeIntervalSince1970: 100)),
        makeItem(id: "c", path: "/p/Screenshot 1.png", format: .png, size: 50, created: Date(timeIntervalSince1970: 200), isScreenshot: true),
        makeItem(id: "d", size: 500, photos: true),
    ]

    func testSortOrders() {
        XCTAssertEqual(MediaSort.sizeDescending.sorted(items).first?.filename, "clip.mov")
        XCTAssertEqual(MediaSort.sizeAscending.sorted(items).first?.filename, "Screenshot 1.png")
        XCTAssertEqual(MediaSort.dateOldest.sorted(items).first?.filename, "clip.mov")
        XCTAssertEqual(MediaSort.nameAscending.sorted(items).first?.filename, "Beach.jpg")
    }

    func testFiltersAndSearchCombine() {
        XCTAssertEqual(MediaQuery(kind: .videos).apply(to: items).map(\.filename), ["clip.mov"])
        XCTAssertEqual(MediaQuery(kind: .screenshots).apply(to: items).count, 1)
        XCTAssertEqual(MediaQuery(source: .photosLibrary).apply(to: items).count, 1)
        XCTAssertEqual(MediaQuery(source: .files).apply(to: items).count, 3)
        XCTAssertEqual(MediaQuery(searchText: "  beach ").apply(to: items).map(\.filename), ["Beach.jpg"])
        XCTAssertTrue(MediaQuery(searchText: "beach", kind: .videos).apply(to: items).isEmpty)
    }

    func testMonthSectionsPreserveOrder() {
        let calendar = Calendar(identifier: .gregorian)
        let jan = calendar.date(from: DateComponents(year: 2024, month: 1, day: 10))!
        let jan2 = calendar.date(from: DateComponents(year: 2024, month: 1, day: 2))!
        let mar = calendar.date(from: DateComponents(year: 2024, month: 3, day: 5))!
        let sorted = MediaSort.dateNewest.sorted([makeItem(id: "1", created: jan), makeItem(id: "2", created: mar), makeItem(id: "3", created: jan2)])
        let sections = MediaSection.byMonth(sorted, calendar: calendar)
        XCTAssertEqual(sections.map(\.items.count), [1, 2])
        XCTAssertEqual(sections.flatMap(\.items).map(\.id), sorted.map(\.id))
    }
}

final class SelectionLogicTests: XCTestCase {
    private let ids = ["a", "b", "c", "d", "e"]

    func testPlainClickSelectsOnlyThatItem() {
        let result = SelectionLogic.click("c", orderedIDs: ids, selection: ["a", "b"], anchor: "a", modifiers: [])
        XCTAssertEqual(result.selection, ["c"])
        XCTAssertEqual(result.anchor, "c")
    }

    func testCommandClickToggles() {
        var result = SelectionLogic.click("c", orderedIDs: ids, selection: ["a"], anchor: "a", modifiers: .command)
        XCTAssertEqual(result.selection, ["a", "c"])
        result = SelectionLogic.click("a", orderedIDs: ids, selection: result.selection, anchor: result.anchor, modifiers: .command)
        XCTAssertEqual(result.selection, ["c"])
    }

    func testShiftClickSelectsRangeInEitherDirection() {
        XCTAssertEqual(SelectionLogic.click("d", orderedIDs: ids, selection: ["b"], anchor: "b", modifiers: .shift).selection, ["b", "c", "d"])
        XCTAssertEqual(SelectionLogic.click("a", orderedIDs: ids, selection: ["c"], anchor: "c", modifiers: .shift).selection, ["a", "b", "c"])
        XCTAssertEqual(SelectionLogic.click("e", orderedIDs: ids, selection: ["a"], anchor: "d", modifiers: [.shift, .command]).selection, ["a", "d", "e"])
    }

    func testArrowNavigationClampsToGrid() {
        XCTAssertEqual(SelectionLogic.move(from: nil, count: 10, columns: 4, direction: .right), 0)
        XCTAssertEqual(SelectionLogic.move(from: 1, count: 10, columns: 4, direction: .down), 5)
        XCTAssertEqual(SelectionLogic.move(from: 8, count: 10, columns: 4, direction: .down), 9)
        XCTAssertEqual(SelectionLogic.move(from: 1, count: 10, columns: 4, direction: .up), 0)
        XCTAssertNil(SelectionLogic.move(from: nil, count: 0, columns: 4, direction: .left))
    }
}

final class AnalysisPruningTests: XCTestCase {
    func testPruningDropsSingletonsAndReassignsKeeper() {
        let a = makeItem(id: "a", path: "/x/a.jpg"), b = makeItem(id: "b", path: "/x/b.jpg"), c = makeItem(id: "c", path: "/x/c.jpg")
        let groups = [
            DuplicateGroup(id: "1", kind: .exact, items: [a, b, c], suggestedKeeperID: a.id, similarity: 1),
            DuplicateGroup(id: "2", kind: .exact, items: [b, c], suggestedKeeperID: b.id, similarity: 1),
        ]
        let pruned = AnalysisStore.prune(groups, removing: [a.id, c.id],
                                         keeperRule: DuplicateSelectionPolicy.suggestedKeeper(forExactDuplicates:))
        XCTAssertTrue(pruned.isEmpty)

        let partly = AnalysisStore.prune(groups, removing: [a.id],
                                         keeperRule: DuplicateSelectionPolicy.suggestedKeeper(forExactDuplicates:))
        XCTAssertEqual(partly.count, 2)
        XCTAssertNotEqual(partly[0].suggestedKeeperID, a.id, "a removed keeper is replaced")
        XCTAssertTrue(partly[0].items.contains { $0.id == partly[0].suggestedKeeperID })
    }
}
